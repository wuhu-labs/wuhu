import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration032Tests {
  @Test func freshCreationDropsCommandsWithoutPersistingALegacyView() async throws {
    let space = try makeSpace()
    #expect(try RawDatabase.open(space.databasePath) { db in
      try db.strings("SELECT name FROM sqlite_master WHERE name IN ('session_commands', 'session_legacy_items')")
    }.isEmpty)
    #expect(try await space.query("SELECT count(*) FROM session_legacy_items").rows == [[.integer(0)]])
    try await space.close()
  }

  @Test func upgradeDropsCommandsOnceAndPreservesAllLegacyRows() async throws {
    let folder = try ScratchFolder("migration-032")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let database = try RawDatabase(path: file.path)
    let payload = #"{"assistant":{"_0":{"content":"old"}}}"#
    try database.access { db in
      try db.execute(sql: """
      INSERT INTO session_contents VALUES ('s', 'entry', ?), ('s', 'unreferenced', '{}');
      INSERT INTO session_pointers VALUES ('s', 0, 0, 'entry'), ('s', 1, 1, 'entry');
      INSERT INTO session_generations VALUES ('s', 0, 0), ('s', 1, 1);
      CREATE TABLE session_commands (session_id TEXT PRIMARY KEY, kind TEXT NOT NULL, instructions TEXT, created_at TEXT NOT NULL);
      INSERT INTO session_commands VALUES ('s', 'compact', 'old command', 'then');
      DELETE FROM grdb_migrations WHERE identifier = '032';
      """, arguments: [payload])
    }
    let upgraded = try Space.open(file: file)
    let reopened = try Space.open(file: file)
    #expect(try database.access { db in
      try db.strings("SELECT name FROM sqlite_master WHERE name IN ('session_commands', 'session_legacy_items')")
    }.isEmpty)
    #expect(try database.access { db in
      try db.strings("SELECT payload FROM session_contents ORDER BY id")
    } == [payload, "{}"])
    #expect(try database.access { db in
      try db.strings("SELECT session_id || ':' || generation || ':' || position || ':' || content_id FROM session_pointers ORDER BY generation")
    } == ["s:0:0:entry", "s:1:1:entry"])
    #expect(try database.access { db in
      try db.strings("SELECT session_id || ':' || generation || ':' || kept_count FROM session_generations ORDER BY generation")
    } == ["s:0:0", "s:1:1"])
    #expect(try database.access { db in
      try db.int("SELECT count(*) FROM grdb_migrations WHERE identifier = '032'")
    } == 1)
    try await reopened.close()
    try await upgraded.close()
    try await original.close()
  }
}
