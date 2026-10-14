import Crypto
import Foundation
import GRDB
import SpaceContract
@testable import SpaceCore
import Testing

@Suite struct MachineV2EnrollmentTests {
  @Test(arguments: ["machine_v2_members", "join_tokens"]) func interruptedEnrollmentRollsBackEveryRowAndAllowsRetry(_ rejectingTable: String) async throws {
    let space = try Space.inMemory()
    let accountsBefore = try await space.accounts().count
    try await space.writer.write { db in
      try db.execute(sql: "CREATE TRIGGER reject_v2_enrollment BEFORE INSERT ON \(rejectingTable) BEGIN SELECT RAISE(ABORT, 'injected enrollment interruption'); END")
    }
    await #expect(throws: DatabaseError.self) { try await space.addMachineV2(name: "atomic-v2") }
    #expect(try await space.resolveMachine("atomic-v2") == nil)
    #expect(try await space.machineV2Members(group: .shared).isEmpty)
    #expect(try await space.accounts().count == accountsBefore)
    #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM join_tokens") } == 0)
    try await space.writer.write { db in try db.execute(sql: "DROP TRIGGER reject_v2_enrollment") }
    let created = try await space.addMachineV2(name: "atomic-v2")
    let persisted = try #require(try await space.resolveMachine("atomic-v2"))
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
    await #expect(throws: JoinTokenRejected.self) { try await space.consumeMachineV2JoinToken(created.token.token, pubkey: pubkey) }
    await #expect(throws: SpaceError.self) { try await space.addMachineV2(name: "atomic-v2") }
  }
}
