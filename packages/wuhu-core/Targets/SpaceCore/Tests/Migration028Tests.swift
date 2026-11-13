import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration028Tests {
  @Test func aRequestTakesItsMessagesConversationAndOneThatNeverPostedGoes() async throws {
    let folder = try ScratchFolder("migration-028")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let database = try RawDatabase(path: file.path)
    try database.access { db in
      try db.execute(sql: """
      ALTER TABLE requests DROP COLUMN conversation_id;
      INSERT INTO conversations (id, kind, window_messages, window_seconds, created_at, grp) VALUES ('dm', 'dm_session', 10, 900, 'now', 'shared');
      INSERT INTO messages (id, conversation_id, sender_id, sender_timezone, kind, request_id, content, created_at)
        VALUES ('r1', 'dm', 'parent', 'GMT', 'request', 'r1', '{}', 'now');
      INSERT INTO requests (id, grp, requester, task, status, brief, created_at, updated_at)
        VALUES ('r1', 'shared', 'parent', 'task', 'open', 'look', 'now', 'now'), ('r2', 'shared', 'parent', 'other', 'open', 'never posted', 'now', 'now');
      DELETE FROM grdb_migrations WHERE identifier = '028';
      """)
    }
    let upgraded = try Space.open(file: file)
    #expect(try database.access { try $0.rows("SELECT id, conversation_id FROM requests").map { [$0[0] as String, $0[1] as String] } } == [["r1", "dm"]])
    try await upgraded.close()
    try await original.close()
  }
}
