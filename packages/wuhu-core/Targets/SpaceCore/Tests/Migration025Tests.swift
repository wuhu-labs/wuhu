import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration025Tests {
  @Test func deadKindsLeaveWhatTheCodeReads() async throws {
    let database = try DatabaseQueue(path: "file:/migration-025-\(UUID())?vfs=memdb")
    let original = try Space(writer: database)
    let date = Date(timeIntervalSince1970: 0)
    let kept: [SubscriptionID: Subscription] = [.init("obs.kept"): .observe(sql: "SELECT 1")]
    let notice = try Sessions.encode(TranscriptItem.notification(.init(id: UUID(), timestamp: date, kind: .requestStall, subscriptionID: .init("s"), content: .init(text: "late"))))
    let (failed, deadline) = (notice.replacingOccurrences(of: "requestStall", with: "childFailed"), notice.replacingOccurrences(of: "requestStall", with: "requestDeadline"))
    let head = try Sessions.encode(TranscriptItem.generationHead(.init(id: UUID(), timestamp: date, summary: "", snapshot: .init(subscriptions: kept), runningWork: [])))
      .replacingOccurrences(of: "\"subscriptions\":[", with: "\"subscriptions\":[\"deadline.r\",{\"requestDeadline\":{\"_0\":1}},")
    try await database.write { db in
      try db.execute(sql: """
      INSERT INTO session_contents VALUES ('s', 'failed', ?), ('s', 'deadline', ?), ('s', 'head', ?);
      INSERT INTO session_queue (session_id, id, input_id, payload, enqueued_at) VALUES ('s', 1, 'i', ?, 'now');
      INSERT INTO notifications (recipient, source, kind, payload, created_at, grp) VALUES
        ('owner', 's', 'child_failed', '{}', 'now', 'shared'), ('owner', 's', 'request_deadline', '{}', 'now', 'shared'), ('owner', 's', 'session_settled', '{}', 'now', 'shared');
      DROP TABLE notifications_retired;
      DELETE FROM grdb_migrations WHERE identifier = '025';
      """, arguments: [failed, deadline, head, deadline])
    }
    let upgraded = try Space(writer: DatabaseQueue(path: database.path))
    let payloads = try await database.read { db in
      try String.fetchAll(db, sql: "SELECT payload FROM session_contents WHERE id <> 'head' UNION ALL SELECT payload FROM session_queue")
    }
    let kinds = try payloads.map { payload -> SystemNotification.Kind? in
      if case let .notification(notice) = try Sessions.decode(QueueInput.self, from: payload) { notice.kind } else { nil }
    }
    #expect(kinds == [.requestStall, .requestStall, .requestStall])
    let migrated = try await database.read { try String.fetchOne($0, sql: "SELECT payload FROM session_contents WHERE id = 'head'")! }
    guard case let .generationHead(decoded) = try Sessions.decode(TranscriptItem.self, from: migrated) else { Issue.record("not a head"); return }
    #expect(decoded.snapshot.subscriptions == kept)
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT kind FROM notifications") } == ["session_settled"])
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT kind FROM notifications_retired ORDER BY kind") } == ["child_failed", "request_deadline"])
    try await upgraded.close()
    try await original.close()
  }
}
