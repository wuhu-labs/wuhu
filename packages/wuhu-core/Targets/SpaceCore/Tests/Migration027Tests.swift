import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration027Tests {
  @Test func aKeyedRequestKeepsItsRowAndLosesKindAndKey() async throws {
    let database = try DatabaseQueue(path: "file:/migration-027-\(UUID())?vfs=memdb")
    let original = try Space(writer: database)
    try await database.write { db in
      try db.execute(sql: """
      ALTER TABLE requests ADD COLUMN kind TEXT;
      ALTER TABLE requests ADD COLUMN key TEXT CHECK (key IS NULL OR kind IS NOT NULL);
      CREATE UNIQUE INDEX requests_by_key ON requests (grp, kind, key);
      CREATE INDEX requests_by_kind_status ON requests (kind, status);
      INSERT INTO requests (id, grp, requester, task, kind, key, status, brief, created_at, updated_at)
        VALUES ('r1', 'shared', 'parent', 'task', 'review', 'pr-7', 'open', 'look', 'now', 'now');
      DELETE FROM grdb_migrations WHERE identifier = '027';
      """)
    }
    let upgraded = try Space(writer: DatabaseQueue(path: database.path))
    let columns = try await database.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('requests')") }
    #expect(!columns.contains("kind") && !columns.contains("key"))
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_index_list('requests') WHERE name LIKE 'requests_by_k%'") } == [])
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT brief FROM requests") } == ["look"])
    try await upgraded.close()
    try await original.close()
  }
}
