import Crypto
import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import SpaceContract
@testable import SpaceCore
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct MachineV2EnrollmentTests {
  @Test(arguments: ["machine_v2_members", "join_tokens"]) func interruptedEnrollmentRollsBackEveryRowAndAllowsRetry(_ rejectingTable: String) async throws {
    let space = try Space.inMemory()
    let accountsBefore = try await space.accounts().count
    try await space.writer.write { db in
      try db.execute(sql: "CREATE TRIGGER reject_v2_enrollment BEFORE INSERT ON \(rejectingTable) BEGIN SELECT RAISE(ABORT, 'injected enrollment interruption'); END")
    }
    await #expect(throws: DatabaseError.self) { try await space.addMachineV2(name: "atomic") }
    #expect(try await space.resolveMachine("atomic") == nil)
    #expect(try await space.machineV2Members(group: .shared).isEmpty)
    #expect(try await space.accounts().count == accountsBefore)
    #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM join_tokens") } == 0)
    try await space.writer.write { db in try db.execute(sql: "DROP TRIGGER reject_v2_enrollment") }
    let created = try await space.addMachineV2(name: "atomic")
    let persisted = try #require(try await space.resolveMachine("atomic"))
    #expect(persisted.id == created.machine.id)
    #expect(persisted.account == created.machine.account)
    #expect(persisted.name == created.machine.name)
    #expect(persisted.group == created.machine.group)
    #expect(try await space.machineV2Members(group: .shared) == [created.machine.id.rawValue])
    let key = Curve25519.Signing.PrivateKey()
    let pubkey = "ed25519:" + key.publicKey.rawRepresentation.base64EncodedString()
    let enrolled = try await space.consumeMachineV2JoinToken(created.token.token, pubkey: pubkey)
    #expect(enrolled.account == created.machine.account)
    #expect(enrolled.capabilities == [.execMachine])
    #expect(Self.identity(try await space.consumeMachineV2JoinToken(created.token.token, pubkey: pubkey)) == Self.identity(enrolled))
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeMachineV2JoinToken(created.token.token, pubkey: Self.label()) }
    await #expect(throws: SpaceError.self) { try await space.addMachineV2(name: "atomic") }
  }

  @Test func oneCallEnrollmentIsAtomicAcrossMachineKeyAndDeviceLink() async throws {
    let space = try Space.inMemory()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let deviceKey = "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let accountsBefore = try await space.accounts().count
    await #expect(throws: SpaceError.malformedPubkey("bogus")) {
      try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: "bogus", device: device.id, enrolledBy: owner.id)
    }
    await #expect(throws: SpaceError.unknownDevice(device.id)) {
      try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: deviceKey, device: device.id, enrolledBy: AccountID(rawValue: "acc_someoneelse"))
    }
    await #expect(throws: SpaceError.alreadyExists(deviceKey)) {
      try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: deviceKey, device: device.id, enrolledBy: owner.id)
    }
    #expect(try await space.resolveMachine("studio") == nil)
    #expect(try await space.accounts().count == accountsBefore)
    #expect(try await space.device(id: device.id)?.machine == nil)

    let pubkey = "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let enrolled = try await space.enrollMachineV2(name: "Studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)
    #expect(enrolled.machine.name == "studio")
    #expect(enrolled.key.createdBy == owner.id)
    #expect(try await space.machine(pubkey: pubkey) == enrolled.machine.id)
    #expect(try await space.device(id: device.id)?.machine == enrolled.machine.id)
    #expect(try await space.machineV2Members(group: .shared) == [enrolled.machine.id.rawValue])
    await #expect(throws: SpaceError.machineNameTaken("studio")) {
      try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
    }
  }

  @Test func machineSelfRevocationNeedsAPresentingLiveKeyAndPurgesTheWholeAccount() async throws {
    let space = try Space.inMemory()
    func label() -> String { "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }
    let (old, current, foreign) = (label(), label(), label())
    let mine = try await space.enrollMachineV2(name: "mine", group: .shared, pubkey: old)
    let theirs = try await space.enrollMachineV2(name: "theirs", group: .shared, pubkey: foreign)
    _ = try await space.addKey(current, account: mine.machine.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    #expect(try await space.revokeMachine(mine.machine.id, presenting: foreign) == false)
    #expect(try await space.revokeMachine(mine.machine.id, presenting: label()) == false)
    #expect(try await space.machine(pubkey: old) == mine.machine.id)
    #expect(try await space.revokeMachine(mine.machine.id, presenting: old))
    #expect(try await space.revokeMachine(mine.machine.id, presenting: current) == false)
    #expect(try await space.machine(pubkey: old) == nil)
    #expect(try await space.machine(pubkey: current) == nil)
    #expect(try await space.machine(mine.machine.id) != nil)
    #expect(try await space.machine(pubkey: foreign) == theirs.machine.id)
  }

  // Stored timestamps round-trip at millisecond precision, so a replay is
  // compared by what identifies it rather than by in-memory Dates.
  private struct Identity: Hashable { let machine: String?, name: String?, group: String?, pubkey: String, account: String, capabilities: Set<KeyCapability>, createdBy: String? }
  private static func identity(_ e: MachineV2Enrollment) -> Identity { Identity(machine: e.machine.id.rawValue, name: e.machine.name, group: e.machine.group.rawValue, pubkey: e.key.pubkey, account: e.key.account.rawValue, capabilities: e.key.capabilities, createdBy: e.key.createdBy?.rawValue) }
  private static func identity(_ k: KeyRecord) -> Identity { Identity(machine: nil, name: nil, group: nil, pubkey: k.pubkey, account: k.account.rawValue, capabilities: k.capabilities, createdBy: k.createdBy?.rawValue) }

  private static func label() -> String { "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }

  private struct Footprint: Equatable {
    let accounts: Int, machines: Int, members: Int, keys: Int
    init(accounts: Int, machines: Int, members: Int, keys: Int) { (self.accounts, self.machines, self.members, self.keys) = (accounts, machines, members, keys) }
    init(_ space: Space) async throws {
      accounts = try await space.accounts().count
      (machines, members, keys) = try await space.writer.read { db in
        try (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM machines")!, Int.fetchOne(db, sql: "SELECT COUNT(*) FROM machine_v2_members")!, Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account_keys")!)
      }
    }
  }

  private func race(_ space: Space, _ attempts: [(name: String, pubkey: String)], device: String, by owner: AccountID) async -> [Result<MachineV2Enrollment, SpaceError>] {
    await withTaskGroup(of: Result<MachineV2Enrollment, SpaceError>.self) { group in
      for attempt in attempts {
        group.addTask {
          do { return .success(try await space.enrollMachineV2(name: attempt.name, group: .shared, pubkey: attempt.pubkey, device: device, enrolledBy: owner)) } catch let error as SpaceError { return .failure(error) } catch { Issue.record("untyped enrollment failure \(error)"); return .failure(.notFound("untyped")) }
        }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }
  }

  @Test(arguments: [true, false]) func concurrentOneCallEnrollmentsLeaveExactlyOneMachine(sameName: Bool) async throws {
    let space = try Space.inMemory()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let deviceKey = Self.label()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let before = try await Footprint(space)
    let sharedKey = Self.label()
    let attempts = (0 ..< 12).map { n in sameName ? (name: "race", pubkey: Self.label()) : (name: "race_\(n)", pubkey: sharedKey) }
    let results = await race(space, attempts, device: device.id, by: owner.id)
    let winners = results.compactMap { try? $0.get() }
    #expect(winners.count == 1)
    for case let .failure(error) in results {
      #expect(error == (sameName ? .machineNameTaken("race") : .alreadyExists(sharedKey)))
    }
    let winner = try #require(winners.first)
    let after = try await Footprint(space)
    #expect(after == Footprint(accounts: before.accounts + 1, machines: before.machines + 1, members: before.members + 1, keys: before.keys + 1))
    #expect(try await space.device(id: device.id)?.machine == winner.machine.id)
    #expect(try await space.machine(pubkey: winner.key.pubkey) == winner.machine.id)
    #expect(try await space.machineV2Members(group: .shared) == [winner.machine.id.rawValue])
  }

  @Test func oneCallEnrollmentReplaysOnlyForTheSamePersonNameAndLiveKey() async throws {
    let space = try Space.inMemory()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let stranger = try await space.addAccount(kind: .human, name: "riley")
    let deviceKey = Self.label()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let pubkey = Self.label()
    let first = try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)
    let footprint = try await Footprint(space)

    #expect(Self.identity(try await space.enrollMachineV2(name: "Studio", group: .shared, pubkey: pubkey, device: device.id, enrolledBy: owner.id)) == Self.identity(first))
    #expect(Self.identity(try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, enrolledBy: owner.id)) == Self.identity(first))
    #expect(try await Footprint(space) == footprint)
    #expect(try await space.device(id: device.id)?.machine == first.machine.id)

    let refusals: [(pubkey: String, by: AccountID?, group: GroupID)] = [
      (Self.label(), owner.id, .shared),
      (pubkey, stranger.id, .shared),
      (pubkey, nil, .shared),
      (pubkey, owner.id, GroupID(rawValue: "elsewhere")),
    ]
    for refusal in refusals {
      await #expect(throws: SpaceError.machineNameTaken("studio")) {
        try await space.enrollMachineV2(name: "studio", group: refusal.group, pubkey: refusal.pubkey, enrolledBy: refusal.by)
      }
    }
    #expect(try await Footprint(space) == footprint)

    #expect(try await space.revokeMachine(first.machine.id, presenting: pubkey))
    let successor = try await space.enrollMachineV2(name: "studio", group: .shared, pubkey: pubkey, enrolledBy: owner.id)
    #expect(successor.machine.id != first.machine.id)
    #expect(try await space.resolveMachine("studio")?.id == successor.machine.id)
  }

  @Test func concurrentReplaysOfOneEnrollmentAllReturnTheSameMachine() async throws {
    let space = try Space.inMemory()
    let owner = try await space.addAccount(kind: .human, name: "morgan")
    let deviceKey = Self.label()
    _ = try await space.addKey(deviceKey, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let device = try await space.upsertDevice(pubkey: deviceKey, installation: "inst", kind: "mac", name: "Mac")
    let before = try await Footprint(space)
    let pubkey = Self.label()
    let results = await race(space, Array(repeating: (name: "twin", pubkey: pubkey), count: 12), device: device.id, by: owner.id)
    let enrolled = try results.map { try $0.get() }
    #expect(Set(enrolled.map(\.machine.id)).count == 1)
    #expect(Set(enrolled.map(Self.identity)).count == 1)
    #expect(try await Footprint(space) == Footprint(accounts: before.accounts + 1, machines: before.machines + 1, members: before.members + 1, keys: before.keys + 1))
    #expect(try await space.device(id: device.id)?.machine == enrolled[0].machine.id)
  }

  @Test func reKeyTokenReplaysToTheSameKeyUntilTheKeyDiesOrTheTokenWouldHaveExpired() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    let space = try withDependencies {
      $0.date = DateGenerator { clock.withLock { $0 } }
    } operation: {
      try Space.inMemory()
    }
    let created = try await space.addMachineV2(name: "rekey_v2")
    let first = Self.label()
    _ = try await space.consumeMachineV2JoinToken(created.token.token, pubkey: first)
    _ = try await space.resetCredentials(account: created.machine.account)
    let rotation = try await space.mintJoinToken(account: created.machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600)
    let next = Self.label()
    let enrolled = try await space.consumeMachineV2JoinToken(rotation.token, pubkey: next)
    #expect(Self.identity(try await space.consumeMachineV2JoinToken(rotation.token, pubkey: next)) == Self.identity(enrolled))
    #expect(Self.identity(try await space.consumeJoinToken(rotation.token, pubkey: next)) == Self.identity(enrolled))
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeMachineV2JoinToken(rotation.token, pubkey: Self.label()) }
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeMachineV2JoinToken(rotation.token, pubkey: first) }
    #expect(try await space.keys(account: created.machine.account).map(\.pubkey) == [next])

    clock.withLock { $0 = $0.addingTimeInterval(600) }
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeMachineV2JoinToken(rotation.token, pubkey: next) }
    #expect(try await space.machine(pubkey: next) == created.machine.id)

    let again = try await space.mintJoinToken(account: created.machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600)
    let last = Self.label()
    _ = try await space.consumeMachineV2JoinToken(again.token, pubkey: last)
    #expect(try await space.revokeMachine(created.machine.id, presenting: last))
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeMachineV2JoinToken(again.token, pubkey: last) }
    #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM join_token_receipts") } == 0)
  }
}
