import Crypto
import Dependencies
import DeterministicDependencies
@testable import Machines
import MachinesContract
import SpaceIDs
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import TenancyContract
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachinesTesting
import SpaceContract
@testable import SpaceCore
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct MachineV2EnrollmentTests {
  @Test func oneCallEnrollmentIsAtomicAcrossMachineKeyAndDeviceLink() async throws {
    let space = try Space.inMemory().registeringMachines()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let deviceKey = "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let accountsBefore = try await space.accounts().count
    await #expect(throws: SpaceError.malformedPubkey("bogus")) {
      try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: "bogus", device: device.id, enrolledBy: owner.id)
    }
    await #expect(throws: SpaceError.unknownDevice(device.id)) {
      try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: deviceKey, device: device.id, enrolledBy: AccountID(rawValue: "acc_someoneelse"))
    }
    #expect(try await space.machineFamily.resolveMachine("studio") == nil)
    #expect(try await space.accounts().count == accountsBefore)
    #expect(try await space.device(id: device.id)?.machine == nil)

    let pubkey = "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let enrolled = try await space.machineFamily.enrollMachineV2(name: "Studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)
    #expect(enrolled.name == "studio")
    #expect(space.machineFamily.directoryCell.row(pubkey: pubkey)?.enrolledBy == owner.id.rawValue)
    #expect(try await space.machineFamily.machine(pubkey: pubkey) == enrolled.id)
    #expect(try await space.device(id: device.id)?.machine == enrolled.id)
    #expect(try await space.machineFamily.machineV2Members(group: .shared) == [enrolled.id.rawValue])
    #expect(try await space.accounts().count == accountsBefore)
    await #expect(throws: SpaceError.machineNameTakenByMachine("studio")) {
      try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
    }
  }

  @Test func machineSelfRevocationNeedsItsOwnLiveKey() async throws {
    let space = try Space.inMemory().registeringMachines()
    let (key, foreign) = (Self.label(), Self.label())
    let mine = try await space.machineFamily.enrollMachineV2(name: "mine", group: .shared, pubkey: key)
    let theirs = try await space.machineFamily.enrollMachineV2(name: "theirs", group: .shared, pubkey: foreign)
    #expect(try await space.machineFamily.revokeMachine(mine.id, presenting: foreign) == false)
    #expect(try await space.machineFamily.revokeMachine(mine.id, presenting: Self.label()) == false)
    #expect(try await space.machineFamily.machine(pubkey: key) == mine.id)
    #expect(try await space.machineFamily.revokeMachine(mine.id, presenting: key))
    #expect(try await space.machineFamily.revokeMachine(mine.id, presenting: key) == false)
    #expect(try await space.machineFamily.machine(pubkey: key) == nil)
    #expect(try await space.machineFamily.machine(mine.id) != nil)
    #expect(try await space.machineFamily.machine(pubkey: foreign) == theirs.id)
  }

  // Stored timestamps round-trip at millisecond precision, so a replay is
  // compared by what identifies it rather than by in-memory Dates.
  private struct Identity: Hashable { let machine: String, name: String?, group: String }
  private static func identity(_ m: MachineRecord) -> Identity { Identity(machine: m.id.rawValue, name: m.name, group: m.group.rawValue) }

  private static func label() -> String { "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }

  private struct Footprint: Equatable {
    let accounts: Int, machines: Int, members: Int, keys: Int
    init(accounts: Int, machines: Int, members: Int, keys: Int) { (self.accounts, self.machines, self.members, self.keys) = (accounts, machines, members, keys) }
    init(_ space: Space) async throws {
      let family = space.machineFamily
      let members = try await family.machineV2Members(group: .shared).count
      let machines = try await family.machines().count
      let keys = family.directoryCell.db.rows(MachineRow.all).count(where: { $0.pubkey != nil })
      self = space.worker.read { reader in
        let accounts = reader.cell(SpaceCell.ID("space")).accounts()
        return Footprint(accounts: accounts.count, machines: machines, members: members, keys: accounts.reduce(keys) { $0 + reader.cell(PersonCell.ID($1.id.rawValue)).keys().count })
      }
    }
  }

  private func race(_ space: Space, _ attempts: [(name: String, pubkey: String)], device: String, by owner: AccountID) async -> [Result<MachineRecord, SpaceError>] {
    await withTaskGroup(of: Result<MachineRecord, SpaceError>.self) { group in
      for attempt in attempts {
        group.addTask {
          do { return .success(try await space.machineFamily.enrollMachineV2(name: attempt.name, group: .shared, pubkey: attempt.pubkey, device: device, enrolledBy: owner)) } catch let error as SpaceError { return .failure(error) } catch { Issue.record("untyped enrollment failure \(error)"); return .failure(.notFound("untyped")) }
        }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }
  }

  @Test(arguments: [true, false]) func concurrentOneCallEnrollmentsEnrollOneKey(sameName: Bool) async throws {
    let space = try Space.inMemory().registeringMachines()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let deviceKey = Self.label()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let sharedKey = Self.label()
    let attempts = (0 ..< 12).map { n in sameName ? (name: "race", pubkey: Self.label()) : (name: "race_\(n)", pubkey: sharedKey) }
    let results = await race(space, attempts, device: device.id, by: owner.id)
    let winners = results.compactMap { try? $0.get() }
    #expect(winners.count == 1)
    for case let .failure(error) in results {
      switch (sameName, error) {
      case (true, .machineNameTakenByMachine("race")), (false, .alreadyExists(sharedKey)): break
      default: Issue.record("unexpected refusal \(error)")
      }
    }
    let winner = try #require(winners.first)
    #expect(try await space.machineFamily.machines().map(\.id) == [winner.id])
    #expect(try await space.device(id: device.id)?.machine == winner.id)
    let key = try #require(space.machineFamily.directoryCell.db.rows(MachineRow.where { $0.id.eq(winner.id.rawValue) }).first?.pubkey)
    #expect(try await space.machineFamily.machine(pubkey: key) == winner.id)
    #expect(attempts.contains { $0.pubkey == key && $0.name == winner.name })
    #expect(try await space.machineFamily.machineV2Members(group: .shared).contains(winner.id.rawValue))
  }

  @Test func oneCallEnrollmentReplaysOnlyForTheSamePersonNameAndLiveKey() async throws {
    let space = try Space.inMemory().registeringMachines()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let stranger = try await space.addAccount(kind: .human, name: "riley")
    let deviceKey = Self.label()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let pubkey = Self.label()
    let first = try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)
    let footprint = try await Footprint(space)

    #expect(Self.identity(try await space.machineFamily.enrollMachineV2(name: "Studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)) == Self.identity(first))
    #expect(Self.identity(try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, enrolledBy: owner.id)) == Self.identity(first))
    #expect(try await Footprint(space) == footprint)
    #expect(try await space.device(id: device.id)?.machine == first.id)

    await #expect(throws: SpaceError.machineNameTakenByMachine("studio")) {
      try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: Self.label(), enrolledBy: owner.id)
    }
    for refusal: (pubkey: String, by: AccountID?, group: GroupID) in [
      (pubkey, stranger.id, .shared),
      (pubkey, nil, .shared),
      (pubkey, owner.id, GroupID(rawValue: "elsewhere")),
    ] {
      await #expect(throws: SpaceError.alreadyExists(pubkey)) {
        try await space.machineFamily.enrollMachineV2(name: "studio", group: refusal.group, pubkey: refusal.pubkey, enrolledBy: refusal.by)
      }
    }
    #expect(try await Footprint(space) == footprint)

    #expect(try await space.machineFamily.revokeMachine(first.id, presenting: pubkey))
    #expect(try await space.machineFamily.resolveMachine("studio")?.id == first.id)
    await #expect(throws: SpaceError.machineNameTakenByMachine("studio")) {
      try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, enrolledBy: owner.id)
    }
    let successor = try await space.machineFamily.enrollMachineV2(name: "studio_two", group: .shared, pubkey: pubkey, enrolledBy: owner.id)
    #expect(successor.id != first.id)
  }

  @Test func aReplayThroughARetiredNameIsRefusedAndLinksNoDevice() async throws {
    let space = try Space.inMemory().registeringMachines()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let deviceKey = Self.label()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let pubkey = Self.label()
    let first = try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, enrolledBy: owner.id)
    let renamed = try await space.machineFamily.renameMachine(first.id, name: "studio_two")
    let footprint = try await Footprint(space)

    await #expect(throws: SpaceError.alreadyExists(pubkey)) {
      try await space.machineFamily.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)
    }
    #expect(try await Footprint(space) == footprint)
    #expect(try await space.device(id: device.id)?.machine == nil)
    #expect(Self.identity(try await space.machineFamily.enrollMachineV2(name: "studio_two", group: .shared, pubkey: pubkey, enrolledBy: owner.id)) == Self.identity(renamed))
  }

  @Test func aRotationTokenReplaysToTheSameKeyUntilTheKeyDiesOrTheTokenExpires() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    let (space, family) = try withDependencies {
      $0.date = DateGenerator { clock.withLock { $0 } }
    } operation: {
      let space = try Space.inMemory().registeringMachines()
      return (space, space.machineFamily)
    }
    let created = try await family.addMachineV2(name: "rekey_v2")
    let first = Self.label()
    #expect(Self.identity(try await family.enrollMachineV2(token: created.token.token, pubkey: first)) == Self.identity(created.machine))
    let rotation = try await family.rotateMachine(created.machine.id)
    #expect(try await family.machine(pubkey: first) == nil)
    await #expect(throws: JoinTokenRejected.self) { try await family.enrollMachineV2(token: created.token.token, pubkey: first) }
    let next = Self.label()
    let enrolled = try await family.enrollMachineV2(token: rotation.token, pubkey: next)
    #expect(Self.identity(try await family.enrollMachineV2(token: rotation.token, pubkey: next)) == Self.identity(enrolled))
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeJoinToken(rotation.token, pubkey: next) }
    await #expect(throws: JoinTokenRejected.self) { try await family.enrollMachineV2(token: rotation.token, pubkey: Self.label()) }
    await #expect(throws: JoinTokenRejected.self) { try await family.enrollMachineV2(token: rotation.token, pubkey: first) }
    #expect(try await family.machine(pubkey: next) == created.machine.id)

    clock.withLock { $0 = $0.addingTimeInterval(3600) }
    await #expect(throws: JoinTokenRejected.self) { try await family.enrollMachineV2(token: rotation.token, pubkey: next) }
    #expect(try await family.machine(pubkey: next) == created.machine.id)

    let again = try await family.rotateMachine(created.machine.id)
    let last = Self.label()
    _ = try await family.enrollMachineV2(token: again.token, pubkey: last)
    #expect(try await family.revokeMachine(created.machine.id, presenting: last))
    await #expect(throws: JoinTokenRejected.self) { try await family.enrollMachineV2(token: again.token, pubkey: last) }
    #expect(try await family.machine(created.machine.id) != nil)
  }

  @Test func aTokenEnrollsNoKeyAnotherMachineHolds() async throws {
    let space = try Space.inMemory().registeringMachines()
    let held = Self.label()
    let holder = try await space.machineFamily.enrollMachineV2(name: "holder", group: .shared, pubkey: held)
    let created = try await space.machineFamily.addMachineV2(name: "fresh")
    await #expect(throws: SpaceError.alreadyExists(held)) { try await space.machineFamily.enrollMachineV2(token: created.token.token, pubkey: held) }
    #expect(try await space.machineFamily.machine(pubkey: held) == holder.id)
    let own = Self.label()
    #expect(try await space.machineFamily.enrollMachineV2(token: created.token.token, pubkey: own).id == created.machine.id)
  }

  @Test func theMachineKeepsOnlyTheSpaceCredentialDigestOfItsToken() async throws {
    let space = try Space.inMemory().registeringMachines()
    let (machine, minted) = try await space.machineFamily.addMachineV2(name: "box")
    let row = try #require(space.machineFamily.directoryCell.db.rows(MachineRow.where { $0.id.eq(machine.id.rawValue) }).first)
    #expect(row.tokenHash == Space.credentialDigest(minted.token.rawValue))
    #expect(row.pubkey == nil)
  }
}
