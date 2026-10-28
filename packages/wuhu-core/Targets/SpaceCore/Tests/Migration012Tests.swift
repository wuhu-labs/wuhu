import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import MachineContract
@testable import SpaceCore
import SpaceFS
import Testing

@Suite(.deterministicDependencies) struct MachineProtocolMigrationTests {
  @Test func upgradeDeletesOnlyMachinesWithoutMembershipAndRunsOnce() async throws {
    let database = try DatabaseQueue()
    let original = try Space(writer: database)
    let old = try await original.addMachine(name: "old_box")
    _ = try await original.renameMachine(old.id, name: "renamed_box")
    let unnamed = try await original.addMachine(name: nil)
    let (kept, _) = try await original.addMachineV2(name: "kept_box")
    let notes = "/_/machines/" + old.id.rawValue + "/AGENTS.md"
    _ = try await original.writeFile(SpacePath(validating: notes), data: Data("keep notes".utf8), in: .shared, acting: .shared, ifMatch: nil, createOnly: true)
    let person = try await original.addAccount(kind: .human, name: "Person")
    for record in [old, unnamed, kept] {
      let id = record.id.rawValue
      let account = record.account.rawValue
      try await database.write { db in
        try db.execute(sql: "INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES (?, ?, 'exec-machine', 'now')", arguments: [id, account])
        try db.execute(sql: "INSERT INTO join_tokens (token_hash, account_id, capabilities, created_at, expires_at, grp) VALUES (?, ?, 'exec-machine', 'now', 'later', 'shared')", arguments: [id, account])
        try db.execute(sql: "INSERT INTO join_token_receipts VALUES (?, ?, 'later')", arguments: [id, id])
        try db.execute(sql: "INSERT INTO group_roles (account_id, grp, role, created_at) VALUES (?, 'shared', 'write', 'now')", arguments: [account])
        try db.execute(sql: "INSERT INTO machine_execs (id, machine_id, stream_id, command, started_at, grp) VALUES (?, ?, 1, '', 'now', 'shared')", arguments: [id, id])
        try db.execute(sql: "INSERT INTO script_execs VALUES (?, 'script', 'caller', 'shared')", arguments: [id])
      }
    }
    try await database.write { db in
      try db.execute(sql: "INSERT INTO devices (id, account_id, pubkey, installation, kind, name, machine_id, created_at, last_seen_at) VALUES ('device', ?, 'device-key', 'install', 'mac', 'Mac', ?, 'now', 'now')", arguments: [person.id.rawValue, old.id.rawValue])
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '012'")
    }
    let tables = ["account_keys", "join_tokens", "join_token_receipts", "group_roles", "machine_execs", "script_execs"]
    let counts = try await database.read { db in
      try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")!) })
    }
    let upgraded = try Space(writer: database)
    #expect(try await upgraded.machines().map(\.id) == [kept.id])
    #expect(try await upgraded.accounts().contains { $0.id == person.id })
    for table in tables {
      #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") } == counts[table]! - 2)
    }
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT name FROM aliases WHERE kind = 'machine'") } == ["kept_box"])
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM devices WHERE machine_id IS NULL") } == 1)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM accounts WHERE id IN (?, ?)", arguments: [old.account.rawValue, unnamed.account.rawValue]) } == 0)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_foreign_key_check") } == 0)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fs_heads WHERE path = ?", arguments: [notes]) } == 1)
    let after = try await upgraded.machines()
    let reopened = try Space(writer: database)
    #expect(try await reopened.machines() == after)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_temp_master WHERE name = 'removed_machines'") } == 0)
  }
}
