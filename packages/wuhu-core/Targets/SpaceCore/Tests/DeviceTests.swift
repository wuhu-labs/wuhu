import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite
struct DeviceTests {
  private func enrolled(_ space: Space, _ seed: String) async throws -> String {
    let account = try await space.addAccount(kind: .human, name: seed)
    _ = try await space.addKey(
      testPubkey(seed), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil,
    )
    return testPubkey(seed)
  }

  @Test func registrationMintsAThreeWordDeviceForTheCallingKey() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "phone")
    let device = try await space.upsertDevice(
      pubkey: pubkey, installation: "inst-1", kind: "phone", name: "Morgan's iPhone",
    )
    #expect(device.id.split(separator: "-").count == 3)
    #expect(device.kind == .phone)
    #expect(device.name == "Morgan's iPhone")
    #expect(device.machine == nil)
    #expect(device.createdAt == fixedDate)
    #expect(try await space.device(pubkey: pubkey) == device)
    #expect(try await space.device(id: device.id) == device)
  }

  @Test func reregisteringTheSameInstallationAdoptsTheRowWithANewKey() async throws {
    let space = try makeSpace()
    let first = try await enrolled(space, "mac")
    let device = try await space.upsertDevice(
      pubkey: first, installation: "inst-1", kind: "mac", name: "Studio",
    )
    let account = try await space.accounts().first { $0.name == "mac" }!
    _ = try await space.addKey(
      testPubkey("mac-again"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil,
    )
    let readopted = try await space.upsertDevice(
      pubkey: testPubkey("mac-again"), installation: "inst-1", kind: "mac", name: "Studio Renamed",
    )
    #expect(readopted.id == device.id)
    #expect(readopted.name == "Studio Renamed")
    #expect(try await space.devices().count == 1)
    #expect(try await space.device(pubkey: first) == nil)
  }

  @Test func aDifferentInstallationOnTheSameAccountIsADifferentDevice() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "pad")
    let account = try await space.accounts().first { $0.name == "pad" }!
    _ = try await space.addKey(
      testPubkey("pad-two"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil,
    )
    let one = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "pad", name: "iPad")
    let two = try await space.upsertDevice(
      pubkey: testPubkey("pad-two"), installation: "b", kind: "pad", name: "Other iPad",
    )
    #expect(one.id != two.id)
    #expect(try await space.devices().count == 2)
  }

  // One key is current for one device: a second installation reaching for a
  // key another device already holds is refused rather than stealing it.
  @Test func aKeyCannotBackTwoInstallations() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "pad")
    _ = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "pad", name: "iPad")
    await #expect(throws: SpaceError.alreadyExists(pubkey)) {
      _ = try await space.upsertDevice(pubkey: pubkey, installation: "b", kind: "pad", name: "iPad")
    }
  }

  @Test func anUnknownKindIsRefused() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "watch")
    await #expect(throws: SpaceError.invalidDeviceKind("watch")) {
      _ = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "watch", name: "Watch")
    }
  }

  @Test func aKeyWithoutTheDeviceCapabilityCannotRegister() async throws {
    let space = try makeSpace()
    let account = try await space.addAccount(kind: .machine, name: "box")
    _ = try await space.addKey(
      testPubkey("box"), account: account.id, capabilities: [.execMachine], createdBy: nil, expiresAt: nil,
    )
    await #expect(throws: SpaceError.unknownDevice(testPubkey("box"))) {
      _ = try await space.upsertDevice(pubkey: testPubkey("box"), installation: "a", kind: "mac", name: "Box")
    }
  }

  @Test func annotationSetsTheNameAndTheMachine() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "mac")
    let device = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "mac", name: "Mac")
    let machine = try await space.addMachine(name: "studio")
    let annotated = try await space.annotateDevice(device.id, name: "Studio Mac", machine: machine.id)
    #expect(annotated.name == "Studio Mac")
    #expect(annotated.machine == machine.id)
    let untouched = try await space.annotateDevice(device.id, name: nil, machine: nil)
    #expect(untouched.name == "Studio Mac")
    #expect(untouched.machine == machine.id)
  }

  @Test func annotatingAnUnknownDeviceFails() async throws {
    let space = try makeSpace()
    await #expect(throws: SpaceError.unknownDevice("no-such-device")) {
      _ = try await space.annotateDevice("no-such-device", name: "x", machine: nil)
    }
  }

  @Test func commandsAreStoredVerbatimAndReadBackInOrder() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "mac")
    let device = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "mac", name: "Mac")
    let first = try await space.issueDeviceCommand(
      device: device.id, payload: #"{"sidebar":"everything"}"#, issuedBy: "se_agent",
    )
    let second = try await space.issueDeviceCommand(
      device: device.id, payload: #"{"sidebar":"/.sidebars/demo.json"}"#, issuedBy: "se_agent",
    )
    #expect(second > first)
    let rows = try await space.query(
      "SELECT n, payload, issued_by FROM device_commands WHERE device_id = '\(device.id)' ORDER BY n",
    )
    #expect(rows.rows.count == 2)
    #expect(rows.rows[0][1] == .text(#"{"sidebar":"everything"}"#))
    #expect(rows.rows[1][1] == .text(#"{"sidebar":"/.sidebars/demo.json"}"#))
    #expect(rows.rows[0][2] == .text("se_agent"))
  }

  @Test func commandsForAnUnknownDeviceAreRefused() async throws {
    let space = try makeSpace()
    await #expect(throws: SpaceError.unknownDevice("nobody")) {
      _ = try await space.issueDeviceCommand(device: "nobody", payload: "{}", issuedBy: "se_agent")
    }
  }

  @Test func devicesAreQueryableLikeTheOtherInducedTables() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "mac")
    let device = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "mac", name: "Mac")
    let rows = try await space.query("SELECT id, name, kind, machine_id FROM devices")
    #expect(rows.rows == [[.text(device.id), .text("Mac"), .text("mac"), .null]])
  }

  @Test func aMessagePostedFromADeviceCarriesItOnTheRecordAndInItsHeader() async throws {
    let space = try makeSpace()
    let pubkey = try await enrolled(space, "mac")
    let device = try await space.upsertDevice(pubkey: pubkey, installation: "a", kind: "mac", name: "Studio")
    let store = space.sessions
    let conversation = try await store.createConversation(members: ["morgan", "alice"], in: .shared)
    let delivery = try await store.post(
      .conversation(conversation),
      messageID: MessageID("m1"),
      sender: Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!, device: device.id),
      content: MessageContent(text: "from the mac"),
    )
    #expect(delivery.message.sender.device == device.id)
    let reread = try await store.messages(conversation: conversation)
    #expect(reread.map(\.sender.device) == [device.id])
  }

  @Test func aMessagePostedWithoutADeviceStaysUnattributed() async throws {
    let space = try makeSpace()
    let store = space.sessions
    let conversation = try await store.createConversation(members: ["morgan", "alice"], in: .shared)
    _ = try await store.post(
      .conversation(conversation),
      messageID: MessageID("m1"),
      sender: Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!),
      content: MessageContent(text: "from a seat"),
    )
    #expect(try await store.messages(conversation: conversation).map(\.sender.device) == [nil])
  }
}
