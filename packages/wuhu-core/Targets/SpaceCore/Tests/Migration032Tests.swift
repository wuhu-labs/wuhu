import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration032Tests {
  @Test func freshCreationDropsCommandsWithoutPersistingALegacyView() async throws {
    let space = try makeSpace()
    #expect(try await space.writer.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name IN ('session_commands', 'session_legacy_items')")
    }.isEmpty)
    #expect(try await space.query("SELECT count(*) FROM session_legacy_items").rows == [[.integer(0)]])
    try await space.close()
  }

  @Test func upgradeDropsCommandsOnceAndPreservesAllLegacyRows() async throws {
    let database = try DatabaseQueue(path: "file:/migration-032-\(UUID())?vfs=memdb", configuration: Space.makeConfiguration(journalMode: .default))
    let original = try Space(writer: database)
    let payload = #"{"assistant":{"_0":{"content":"old"}}}"#
    try await database.write { db in
      try db.execute(sql: """
      INSERT INTO session_contents VALUES ('s', 'entry', ?), ('s', 'unreferenced', '{}');
      INSERT INTO session_pointers VALUES ('s', 0, 0, 'entry'), ('s', 1, 1, 'entry');
      INSERT INTO session_generations VALUES ('s', 0, 0), ('s', 1, 1);
      CREATE TABLE session_commands (session_id TEXT PRIMARY KEY, kind TEXT NOT NULL, instructions TEXT, created_at TEXT NOT NULL);
      INSERT INTO session_commands VALUES ('s', 'compact', 'old command', 'then');
      DELETE FROM grdb_migrations WHERE identifier = '032';
      """, arguments: [payload])
    }
    let upgraded = try Space(writer: DatabaseQueue(path: database.path, configuration: Space.makeConfiguration(journalMode: .default)))
    let reopened = try Space(writer: DatabaseQueue(path: database.path, configuration: Space.makeConfiguration(journalMode: .default)))
    #expect(try await database.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name IN ('session_commands', 'session_legacy_items')")
    }.isEmpty)
    #expect(try await database.read { db in
      try String.fetchAll(db, sql: "SELECT payload FROM session_contents ORDER BY id")
    } == [payload, "{}"])
    #expect(try await database.read { db in
      try String.fetchAll(db, sql: "SELECT session_id || ':' || generation || ':' || position || ':' || content_id FROM session_pointers ORDER BY generation")
    } == ["s:0:0:entry", "s:1:1:entry"])
    #expect(try await database.read { db in
      try String.fetchAll(db, sql: "SELECT session_id || ':' || generation || ':' || kept_count FROM session_generations ORDER BY generation")
    } == ["s:0:0", "s:1:1"])
    #expect(try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier = '032'")
    } == 1)
    try await reopened.close()
    try await upgraded.close()
    try await original.close()
  }
}
