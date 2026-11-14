import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration055Tests {
  static let retired = [
    "execution_worker_owners", "fs_heads_by_parent", "notifications_retired", "schema_compactions", "session_command_tokens", "session_context", "session_generations",
    "session_worker_assignments", "session_worker_incarnations", "worker_script_owners", "wmd_checkpoints", "wmd_log", "wmd_snapshots",
  ]

  @Test func aFreshSpaceHasNoneOfTheRetiredTables() async throws {
    let space = try Space.inMemory()
    #expect(try RawDatabase.open(space.databasePath) { db in try Self.retired.filter { try db.tableExists($0) } } == [])
    #expect(try await space.query("SELECT count(*) FROM session_legacy_items").rows == [[.integer(0)]])
    try await space.close()
  }

  @Test func upgradeDropsThemWithTheirIndexesAndTriggersAndKeepsEveryOtherRow() async throws {
    let folder = try ScratchFolder("migration-055")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    _ = try await original.fs(.shared).write("/kept.md", Data("# Kept\n".utf8), ifMatch: nil)
    try await original.close()
    let database = try RawDatabase(path: file.path)
    // The retired tables as an older space carries them. The wmd_ ones are
    // left out on purpose, so the upgrade also meets tables that IF EXISTS skips.
    let before = try database.access { db in
      try db.execute(sql: """
      CREATE TABLE schema_compactions (name TEXT NOT NULL PRIMARY KEY, applied_at TEXT NOT NULL);
      INSERT INTO schema_compactions VALUES ('wuhu-45', '2026-01-01T00:00:00Z');
      """)
      try Migration001.apply(db)
      try Migration025.apply(db)
      try db.execute(sql: """
      INSERT INTO session_contents VALUES ('s', 'entry', '{"assistant":{"_0":{"content":"old"}}}');
      INSERT INTO session_generations VALUES ('s', 0, 0);
      INSERT INTO session_context VALUES ('s', 1, 2, '2026-01-01T00:00:00Z');
      INSERT INTO session_command_tokens VALUES ('s', 'token');
      CREATE INDEX session_context_by_reported ON session_context (reported_at);
      CREATE TRIGGER session_generations_kept AFTER INSERT ON session_generations BEGIN SELECT 1; END;
      DELETE FROM grdb_migrations WHERE identifier = '055';
      """)
      return try Self.rowCounts(db)
    }
    #expect(Set(Self.retired).subtracting(before.keys) == ["wmd_checkpoints", "wmd_log", "wmd_snapshots"])
    let upgraded = try Space.open(file: file)
    try database.access { db throws in
      #expect(try Self.retired.filter { try db.tableExists($0) } == [])
      #expect(try db.strings("SELECT name FROM sqlite_master WHERE name IN ('session_context_by_reported', 'session_generations_kept')") == [])
      #expect(try Self.rowCounts(db) == before.filter { !Self.retired.contains($0.key) })
      #expect(try db.int("SELECT count(*) FROM grdb_migrations WHERE identifier = '055'") == 1)
    }
    #expect(try await upgraded.fs(.shared).read("/kept.md").1 == Data("# Kept\n".utf8))
    #expect(try await upgraded.query("SELECT count(*) FROM session_legacy_items").rows == [[.integer(0)]])
    try await upgraded.close()
  }

  private static func rowCounts(_ db: MigrationDB) throws -> [String: Int] {
    try Dictionary(uniqueKeysWithValues: db.strings("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'").map { table in
      (table, try db.int("SELECT count(*) FROM \"\(table.replacing("\"", with: "\"\""))\"") ?? 0)
    })
  }
}
