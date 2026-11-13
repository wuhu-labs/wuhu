import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration031Tests {
  @Test func theJournalForgetsAttachmentsAndKeepsTheirRowsAndRevisions() async throws {
    let folder = try ScratchFolder("migration-031")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let database = try RawDatabase(path: file.path)
    try database.access { db in
      try db.execute(sql: """
      INSERT INTO revisions (rev, mtime, grp) VALUES (901, 'then', 'shared'), (902, 'then', 'shared');
      INSERT INTO fs_heads (grp, path, parent_path, kind, blob_hash, size, etag, rev, mtime) VALUES
        ('shared', '/_/conversations', '/_', 'directory', NULL, 0, '', 901, 'then'),
        ('shared', '/_/conversations/dm/attachments/a.md', '/_/conversations/dm/attachments', 'file', 'h1', 7, '', 901, 'then'),
        ('shared', '/_/conversationsx', '/_', 'file', 'h2', 1, '', 902, 'then'),
        ('shared', '/notes/attachments/c.png', '/notes/attachments', 'file', 'h3', 1, '', 902, 'then');
      INSERT INTO fs_versions (grp, path, rev, kind, blob_hash, op) VALUES
        ('shared', '/_/conversations', 901, 'directory', NULL, 'write'),
        ('shared', '/_/conversations/dm/attachments/a.md', 901, 'file', 'h1', 'write'),
        ('shared', '/notes/attachments/c.png', 902, 'file', 'h3', 'write');
      INSERT INTO docs (grp, path, title) VALUES ('shared', '/_/conversations/dm/attachments/a.md', 'A'), ('shared', '/notes/b.md', 'B');
      INSERT INTO attachments (conversation_id, path, blob, size, created_at) VALUES ('dm', '/_/conversations/dm/attachments/a.md', 'h1', 7, 'then');
      DELETE FROM grdb_migrations WHERE identifier = '031';
      """)
    }
    let upgraded = try Space.open(file: file)
    let left = try database.access { db in
      try ["fs_heads", "fs_versions", "docs", "attachments"].map { try db.strings("SELECT path FROM \($0) WHERE path LIKE '/_/conv%' OR path LIKE '/notes/%' ORDER BY path") }
        + [try db.strings("SELECT CAST(rev AS TEXT) FROM revisions WHERE rev > 900 ORDER BY rev")]
    }
    #expect(left == [
      ["/_/conversationsx", "/notes/attachments/c.png"], ["/notes/attachments/c.png"], ["/notes/b.md"],
      ["/_/conversations/dm/attachments/a.md"], ["901", "902"],
    ])
    try await upgraded.close()
    try await original.close()
  }
}
