import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MigrationTests {
  private func database() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    return try DatabaseQueue(path: "file:/migration-\(UUID())?vfs=memdb", configuration: configuration)
  }

  private func baseline(_ database: DatabaseQueue) async throws -> Space {
    let space = try Space(writer: database)
    _ = try await space.addAccount(kind: .human, name: "Kept")
    let machine = try await space.addMachine(name: "box").id
    let exec = try await space.claimExec(machine: machine, caller: "caller", toolCallID: .init("call"))
    try await database.write { db in
      try db.execute(sql: "DROP TABLE grdb_migrations")
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_spec")
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_end_owed")
      try db.execute(sql: "ALTER TABLE session_api_receipts DROP COLUMN request")
      try db.execute(sql: "CREATE TABLE exec_jobs (exec_id TEXT PRIMARY KEY, spec TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO exec_jobs VALUES (?, '{}')", arguments: [exec.record.id.rawValue])
    }
    return space
  }

  @Test func failedUpgradeRollsBackAndCanBeRetried() async throws {
    let database = try database()
    let original = try await baseline(database)
    try await database.write { db in try db.execute(sql: "ALTER TABLE exec_jobs DROP COLUMN spec") }
    #expect(throws: DatabaseError.self) { try Space(writer: database) }
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 0)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_table_info('machine_execs') WHERE name = 'tool_spec'") } == 0)
    try await database.write { db in
      try db.execute(sql: "ALTER TABLE exec_jobs ADD COLUMN spec TEXT")
      try db.execute(sql: "UPDATE exec_jobs SET spec = '{}'")
    }
    let reopened = try DatabaseQueue(path: database.path)
    let space = try Space(writer: reopened)
    #expect(try await space.accounts().contains { $0.name == "Kept" })
    #expect(try await space.owedExecs().map(\.toolSpec) == ["{}"])
    try await original.close()
    try await space.close()
  }

  @Test func upgradePreservesRowsAndRunsOnlyOnce() async throws {
    let database = try database()
    let original = try await baseline(database)
    let firstConnection = try DatabaseQueue(path: database.path)
    let first = try Space(writer: firstConnection)
    #expect(try await first.accounts().contains { $0.name == "Kept" })
    let owed = try #require(try await first.owedExecs().first)
    #expect(owed.toolSpec == "{}")
    #expect(owed.toolEndOwed)
    let identity = try await first.identity()
    try await database.write { db in
      try db.execute(sql: "INSERT INTO exec_jobs VALUES (?, 'changed')", arguments: [owed.id.rawValue])
    }
    let secondConnection = try DatabaseQueue(path: database.path)
    let second = try Space(writer: secondConnection)
    #expect(try await second.identity() == identity)
    #expect(try await second.accounts().contains { $0.name == "Kept" })
    #expect(try await second.owedExecs() == [owed])
    try await original.close()
    try await first.close()
    try await second.close()
  }

  @Test func existingForeignKeyViolationsDoNotPreventUpgrade() async throws {
    let database = try database()
    let original = try await baseline(database)
    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('shared', 'missing', '2026-01-01T00:00:00Z')")
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let connection = try DatabaseQueue(path: database.path)
    let upgraded = try Space(writer: connection)
    #expect(try await upgraded.accounts().contains { $0.name == "Kept" })
    #expect(try await upgraded.owedExecs().map(\.toolSpec) == ["{}"])
    try await original.close()
    try await upgraded.close()
  }

  @Test func missingBaselineCompactionIsRefusedWithoutApplyingMigration() async throws {
    let database = try database()
    let original = try await baseline(database)
    try await database.write { db in try db.execute(sql: "DELETE FROM schema_compactions WHERE name = 'wuhu-45'") }
    #expect(throws: SpaceError.needsMigration("wuhu-45")) { try Space(writer: database) }
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 0)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_table_info('machine_execs') WHERE name = 'tool_spec'") } == 0)
    try await original.close()
  }

  @Test func freshBootRecordsLinksCompactionWithItsMigration() async throws {
    let database = try database()
    let space = try Space(writer: database)
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT name FROM schema_compactions ORDER BY name") } == ["wuhu-45", "wuhu-45-links"])
    try await space.close()
  }

  @Test func newerDatabaseIsRefusedWithoutChanges() async throws {
    let database = try database()
    let original = try Space(writer: database)
    try await database.write { db in try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('003'), ('002')") }
    #expect(throws: SpaceError.unknownMigrations(["002", "003"])) { try Space(writer: database) }
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") } == ["001", "002", "003"])
    try await original.close()
  }
}
