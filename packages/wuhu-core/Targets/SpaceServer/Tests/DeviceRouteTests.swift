import Assertion
import Crypto
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceServer
import Testing

@Suite struct DeviceRouteTests {
  let harness: Harness
  let identity: String
  let key = Curve25519.Signing.PrivateKey()

  init() async throws {
    harness = try Harness(dev: false)
    identity = try await harness.space.identity().rawValue
  }

  private func enroll(
    _ key: Curve25519.Signing.PrivateKey,
    capabilities: Set<KeyCapability> = [.device],
  ) async throws -> AccountID {
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    _ = try await harness.space.addKey(
      key.pubkeyLabel, account: account.id, capabilities: capabilities, createdBy: nil, expiresAt: nil,
    )
    return account.id
  }

  private func bearer(_ key: Curve25519.Signing.PrivateKey) throws -> String {
    try AssertionClaims(key: key.pubkeyLabel, space: identity, expiresAt: fixedDate.addingTimeInterval(3600))
      .signed(by: key).rawValue
  }

  private func call(
    _ method: Fetch.Method,
    _ path: String,
    as key: Curve25519.Signing.PrivateKey?,
    body: JSONValue? = nil,
  ) async throws -> Response {
    var request = Request(url: URL(string: "http://space" + path)!, method: method)
    if let key { request.headers[.authorization] = "Bearer " + (try bearer(key)) }
    if let body { request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json") }
    return try await harness.api(request)
  }

  private func register(
    _ key: Curve25519.Signing.PrivateKey,
    installation: String = "install-1",
    kind: String = "mac",
    name: String = "Studio",
  ) async throws -> DevicePayload {
    let response = try await call(.put, "/v1/device", as: key, body: [
      "installation": .string(installation), "kind": .string(kind), "name": .string(name),
    ])
    #expect(response.status == .ok)
    return try JSONValueDecoder().decode(DevicePayload.self, from: try await json(response))
  }

  @Test func registrationMintsADeviceAndIsIdempotent() async throws {
    _ = try await enroll(key)
    let first = try await register(key)
    #expect(first.kind == "mac")
    #expect(first.name == "Studio")
    #expect(first.machine == nil)
    let again = try await register(key, name: "Studio Renamed")
    #expect(again.id == first.id)
    #expect(again.name == "Studio Renamed")
    let listed = try JSONValueDecoder().decode(
      DevicesOutput.self, from: try await json(try await call(.get, "/v1/devices", as: key)),
    )
    #expect(listed.devices.map(\.id) == [first.id])
  }

  @Test func registrationNeedsADeviceCapableKey() async throws {
    let machineKey = Curve25519.Signing.PrivateKey()
    let account = try await harness.space.addAccount(kind: .machine, name: nil)
    _ = try await harness.space.addKey(
      machineKey.pubkeyLabel, account: account.id, capabilities: [.execMachine], createdBy: nil, expiresAt: nil,
    )
    let response = try await call(.put, "/v1/device", as: machineKey, body: [
      "installation": "install-1", "kind": "mac", "name": "Box",
    ])
    #expect(response.status == .unauthorized)
    #expect(try await harness.space.devices().isEmpty)
  }

  @Test func anUnknownKindIsRefused() async throws {
    _ = try await enroll(key)
    let response = try await call(.put, "/v1/device", as: key, body: [
      "installation": "install-1", "kind": "watch", "name": "Watch",
    ])
    #expect(response.status == .badRequest)
  }

  @Test func annotationNamesTheDeviceAndItsMachine() async throws {
    _ = try await enroll(key)
    let device = try await register(key)
    let machine = try await harness.space.addMachine(name: "studio")
    let annotated = try JSONValueDecoder().decode(DevicePayload.self, from: try await json(
      try await call(.patch, "/v1/device/\(device.id)", as: key, body: [
        "name": "Studio Mac", "machine": "studio",
      ]),
    ))
    #expect(annotated.name == "Studio Mac")
    #expect(annotated.machine == machine.id.rawValue)
    let untouched = try JSONValueDecoder().decode(DevicePayload.self, from: try await json(
      try await call(.patch, "/v1/device/\(device.id)", as: key, body: .object([:])),
    ))
    #expect(untouched.name == "Studio Mac")
    #expect(untouched.machine == machine.id.rawValue)
  }

  @Test func anotherAccountCannotAnnotateYourDevice() async throws {
    _ = try await enroll(key)
    let device = try await register(key)
    let stranger = Curve25519.Signing.PrivateKey()
    _ = try await enroll(stranger)
    let response = try await call(.patch, "/v1/device/\(device.id)", as: stranger, body: ["name": "Mine now"])
    #expect(response.status == .forbidden)
  }

  @Test func acommandIsStoredVerbatimForTheDeviceToRead() async throws {
    _ = try await enroll(key)
    let device = try await register(key)
    let issued = try JSONValueDecoder().decode(DeviceCommandOutput.self, from: try await json(
      try await call(.post, "/v1/device/\(device.id)/command", as: key, body: [
        "payload": ["sidebar": "/.sidebars/demo.json"],
      ]),
    ))
    #expect(issued.n >= 1)
    let rows = try await harness.space.query(
      "SELECT n, payload FROM device_commands WHERE device_id = '\(device.id)'",
      as: .shared(.anonymous),
    )
    #expect(rows.rows == [[.integer(Int64(issued.n)), .text(#"{"sidebar":"/.sidebars/demo.json"}"#)]])
  }

  @Test func acommandForAnUnknownDeviceIsNotFound() async throws {
    _ = try await enroll(key)
    let response = try await call(.post, "/v1/device/nobody-at-all/command", as: key, body: ["payload": .object([:])])
    #expect(response.status == .notFound)
  }
}

// The attribution is server-side, so it is only real over the session stack
// that actually posts messages.
@Suite struct DeviceAttributionRouteTests {
  @discardableResult
  private func enrolled(
    _ space: Space,
    _ key: Curve25519.Signing.PrivateKey,
    capabilities: Set<KeyCapability>,
  ) async throws -> String {
    let account = try await space.addAccount(kind: .human, name: nil)
    let record = try await space.addKey(
      key.pubkeyLabel, account: account.id, capabilities: capabilities, createdBy: nil, expiresAt: nil,
    )
    return try await space.mintPersona(key: record).name
  }

  private func bearer(_ key: Curve25519.Signing.PrivateKey, space: String) throws -> String {
    try AssertionClaims(key: key.pubkeyLabel, space: space, expiresAt: Date().addingTimeInterval(3600))
      .signed(by: key).rawValue
  }

  @Test func amessagePostedFromADeviceCarriesItAndAnUnattributedSeatDoesNot() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let identity = try await harness.space.identity().rawValue
      let phone = Curve25519.Signing.PrivateKey()
      let seat = Curve25519.Signing.PrivateKey()
      let phonePersona = try await enrolled(harness.space, phone, capabilities: [.device, .seat])
      try await enrolled(harness.space, seat, capabilities: [.seat])

      let registered = try await harness.put(
        "/v1/device",
        ["installation": "install-1", "kind": "phone", "name": "Morgan's iPhone"],
        bearer: try bearer(phone, space: identity),
      )
      #expect(registered.status == .ok)
      let device = try JSONValueDecoder().decode(DevicePayload.self, from: try await json(registered))

      let conversation = try await harness.space.sessions.createConversation(members: [phonePersona, "alice"], in: .shared)
      for (key, text) in [(phone, "from the phone"), (seat, "from a terminal")] {
        let posted = try await harness.post(
          "/v1/conversation/message",
          ["message": .string(text), "conversation": .string(conversation.rawValue)],
          bearer: try bearer(key, space: identity),
        )
        #expect(posted.status == .ok)
      }

      let stored = try await harness.space.sessions.messages(conversation: conversation)
      #expect(stored.map(\.sender.device) == [device.id, nil])
      #expect(try await harness.space.deviceNames()[device.id] == "Morgan's iPhone")
      #expect(stored[0].sender.device.map { device in
        MessageHeader(
          sender: stored[0].sender.id, timestamp: stored[0].createdAt, timeZone: stored[0].sender.timeZone,
          source: .conversation(conversation), kind: .message, device: device,
        )
        .attributing([:], devices: [device: "Morgan's iPhone"]).render()
      }?.hasSuffix("<device>Morgan's iPhone (\(device.id))</device>") == true)
    }
  }
}
