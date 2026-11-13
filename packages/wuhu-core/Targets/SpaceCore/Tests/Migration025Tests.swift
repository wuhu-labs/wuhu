import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration025Tests {
  @Test func deadKindsLeaveWhatTheCodeReads() async throws {
    let folder = try ScratchFolder("migration-025")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let database = try RawDatabase(path: file.path)
    let failed = #"{"notification":{"_0":{"kind":"childFailed"}}}"#
    let deadline = #"{"notification":{"_0":{"kind":"requestDeadline"}}}"#
    let head = #"{"generationHead":{"_0":{"snapshot":{"subscriptions":["deadline.r",{"requestDeadline":{"_0":1}},"obs.kept",{"observe":{"sql":"SELECT 1"}}]}}}}"#
    try database.access { db in
      try db.execute(sql: """
      INSERT INTO session_contents VALUES ('s', 'failed', ?), ('s', 'deadline', ?), ('s', 'head', ?);
      INSERT INTO session_queue (session_id, id, input_id, payload, enqueued_at) VALUES ('s', 1, 'i', ?, 'now');
      INSERT INTO notifications (recipient, source, kind, payload, created_at, grp) VALUES
        ('owner', 's', 'child_failed', '{}', 'now', 'shared'), ('owner', 's', 'request_deadline', '{}', 'now', 'shared'), ('owner', 's', 'session_settled', '{}', 'now', 'shared');
      DROP TABLE notifications_retired;
      DELETE FROM grdb_migrations WHERE identifier = '025';
      """, arguments: [failed, deadline, head, deadline])
    }
    let upgraded = try Space.open(file: file)
    #expect(try database.access { db in
      try db.strings("SELECT json_extract(payload, '$.notification._0.kind') FROM session_contents WHERE id <> 'head' UNION ALL SELECT json_extract(payload, '$.notification._0.kind') FROM session_queue")
    } == ["requestStall", "requestStall", "requestStall"])
    #expect(try database.access { db in
      try db.string("SELECT json_extract(payload, '$.generationHead._0.snapshot.subscriptions') FROM session_contents WHERE id = 'head'")
    } == #"["obs.kept",{"observe":{"sql":"SELECT 1"}}]"#)
    #expect(try database.access { try $0.strings("SELECT kind FROM notifications") } == ["session_settled"])
    #expect(try database.access { try $0.strings("SELECT kind FROM notifications_retired ORDER BY kind") } == ["child_failed", "request_deadline"])
    try await upgraded.close()
    try await original.close()
  }
}
