import DeterministicDependencies
import Foundation
import GRDB
import SessionDomain
@testable import SpaceCore
import Testing

// A space from before migration 008: request state lived on messages
// (`deadline_at`) and in the fold of finals, with no `requests` table.
@Suite(.deterministicDependencies) struct Migration008Tests {
  private func database() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    return try DatabaseQueue(path: "file:/migration-008-\(UUID())?vfs=memdb", configuration: configuration)
  }

  // Six requests: answered, on an archived task, past its deadline, before
  // its deadline, without one, and with its stall alert fired. Then the
  // schema goes back to before 008 (and 009, which builds on it).
  private func before008(_ database: DatabaseQueue) async throws -> Space {
    let space = try Space(writer: database)
    let store = space.sessions
    let parent = try await store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
    for id in ["done", "gone", "late", "pending", "plain", "stalled"] {
      let task = try await store.createSession(
        group: .shared, title: id, kind: .task, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test),
      )
      _ = try await store.openRequest(
        on: task, from: .session(parent), messageID: MessageID(id), text: "brief \(id)", deadline: nil, stallSeconds: id == "stalled" ? 600 : nil,
      )
      switch id {
      case "done": _ = try await store.report(task, request: RequestID(id), kind: .final, messageID: MessageID("final"), text: "all good")
      case "gone": _ = try await store.archive(task, grace: .seconds(60))
      case "stalled": try await store.checkRequestStall(parent, subscriptionID: .stall(RequestID(id)), now: fixedDate.addingTimeInterval(600))
      default: break
      }
    }
    try await database.write { db in
      try db.execute(sql: """
      DELETE FROM grdb_migrations WHERE identifier IN ('008', '009');
      CREATE TABLE "session_subscriptions" (
        "session_id" TEXT NOT NULL, "subscription_id" TEXT NOT NULL, "payload" TEXT NOT NULL, "next_fire_at" TEXT,
        "marker" TEXT, "last_fired_at" TEXT, "armed_at" TEXT NOT NULL, PRIMARY KEY ("session_id", "subscription_id")
      );
      INSERT INTO session_subscriptions SELECT owner, subscription_id, payload, next_fire_at, marker, last_fired_at, armed_at FROM subscription_slots;
      DROP TABLE subscription_slots;
      DROP TABLE subscription_firings;
      DROP INDEX sessions_by_firing;
      DROP INDEX messages_by_firing;
      DROP INDEX revision_actors_by_via;
      ALTER TABLE sessions DROP COLUMN firing;
      ALTER TABLE messages DROP COLUMN firing;
      DROP TABLE requests;
      ALTER TABLE messages ADD COLUMN deadline_at TEXT;
      UPDATE messages SET deadline_at = '2000-01-01T00:00:00.000Z' WHERE id = 'late';
      UPDATE messages SET deadline_at = '2999-01-01T00:00:00.000Z' WHERE id = 'pending';
      """)
    }
    return space
  }

  @Test func `every request message becomes one row and deadline_at is dropped`() async throws {
    let database = try database()
    let original = try await before008(database)
    let reopened = try DatabaseQueue(path: database.path)
    let space = try Space(writer: reopened)
    let rows = try await reopened.read { db in
      try Row.fetchAll(db, sql: "SELECT id, status, brief, result, deadline_at, kind, key FROM requests ORDER BY id")
        .map { [$0["id"], $0["status"], $0["brief"], $0["result"], $0["deadline_at"], $0["kind"], $0["key"]] as [String?] }
    }
    #expect(rows == [
      ["done", "done", "brief done", #""all good""#, nil, nil, nil],
      ["gone", "failed", "brief gone", nil, nil, nil, nil],
      ["late", "overdue", "brief late", nil, "2000-01-01T00:00:00.000Z", nil, nil],
      ["pending", "open", "brief pending", nil, "2999-01-01T00:00:00.000Z", nil, nil],
      ["plain", "open", "brief plain", nil, nil, nil, nil],
      ["stalled", "stalled", "brief stalled", nil, nil, nil, nil],
    ])
    #expect(try await reopened.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_table_info('messages') WHERE name = 'deadline_at'") } == 0)
    try await original.close()
    try await space.close()
  }

  @Test func `the backfill reports what it made`() async throws {
    let database = try database()
    let original = try await before008(database)
    let backfill = try await database.writeWithoutTransaction { db in
      var backfill: Migration008.Backfill?
      try db.inTransaction {
        backfill = try Migration008.run(db)
        return .rollback
      }
      return backfill
    }
    #expect(backfill == Migration008.Backfill(requestMessages: 6, rows: ["done": 1, "failed": 1, "open": 2, "overdue": 1, "stalled": 1]))
    try await original.close()
  }

  @Test func `a request message without exactly one row stops the migration and changes nothing`() async throws {
    let database = try database()
    let original = try await before008(database)
    try await database.write { db in
      try db.execute(sql: "DELETE FROM conversation_members WHERE member_kind = 'session' AND member IN (SELECT id FROM sessions WHERE title = 'plain')")
    }
    let reopened = try DatabaseQueue(path: database.path)
    #expect(throws: Migration008.Unmatched.self) { try Space(writer: reopened) }
    #expect(try await reopened.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'requests')") } == false)
    #expect(try await reopened.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_table_info('messages') WHERE name = 'deadline_at'") } == 1)
    #expect(try await reopened.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier = '008'") } == 0)
    try await original.close()
  }
}
