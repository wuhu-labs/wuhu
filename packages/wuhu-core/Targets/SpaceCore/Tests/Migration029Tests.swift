import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration029Tests {
  @Test func aJournalledAttachmentBecomesARowOfTheConversationHomedInItsGroup() async throws {
    let database = try DatabaseQueue(path: "file:/migration-029-\(UUID())?vfs=memdb", configuration: Space.makeConfiguration(journalMode: .default))
    let original = try Space(writer: database)
    try await database.write { db in
      try db.execute(sql: """
      DROP TABLE attachments;
      INSERT INTO conversations (id, kind, window_messages, window_seconds, created_at, grp) VALUES ('dm', 'dm_session', 10, 900, 'now', 'shared');
      INSERT INTO fs_heads (grp, path, parent_path, kind, blob_hash, size, etag, rev, mtime) VALUES
        ('shared', '/_/conversations/dm/attachments/2026/01/02/030405Z', '/_/conversations/dm/attachments/2026/01/02', 'directory', NULL, 0, '', 1, 'then'),
        ('shared', '/_/conversations/dm/attachments/2026/01/02/030405Z/a.png', '/_/conversations/dm/attachments/2026/01/02/030405Z', 'file', 'h1', 7, '', 1, 'then'),
        ('other', '/_/conversations/dm/attachments/2026/01/02/030405Z/b.png', '/_/conversations/dm/attachments/2026/01/02/030405Z', 'file', 'h2', 9, '', 1, 'then'),
        ('shared', '/notes/attachments/c.png', '/notes/attachments', 'file', 'h3', 1, '', 1, 'then');
      DELETE FROM grdb_migrations WHERE identifier = '029';
      """)
    }
    let upgraded = try Space(writer: DatabaseQueue(path: database.path, configuration: Space.makeConfiguration(journalMode: .default)))
    let rows = try await database.read { db in
      try Row.fetchAll(db, sql: "SELECT conversation_id, path, blob, size, created_at FROM attachments").map { row in
        [row[0] as String, row[1] as String, row[2] as String, String(row[3] as Int), row[4] as String]
      }
    }
    #expect(rows == [["dm", "/_/conversations/dm/attachments/2026/01/02/030405Z/a.png", "h1", "7", "then"]])
    try await upgraded.close()
    try await original.close()
  }
}
