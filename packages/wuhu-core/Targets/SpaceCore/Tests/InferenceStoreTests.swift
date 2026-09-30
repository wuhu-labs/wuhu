import Foundation
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct InferenceStoreTests {
  private func record(_ session: SessionID, id: String, failed: Bool = false) -> InferenceRecord {
    InferenceRecord(
      id: id, session: session, at: fixedDate,
      provider: "codex", model: "configured", servedModel: failed ? nil : "served", effort: "high",
      input: failed ? nil : 30, cacheRead: failed ? nil : 200, cacheWrite: failed ? nil : 0,
      output: failed ? nil : 80, reasoning: failed ? nil : 60,
      outcome: failed ? "timeout" : "ok", error: failed ? "idleTimeout" : nil,
      durationMs: 1200, ttftMs: failed ? nil : 100,
    )
  }

  @Test func storesEachCallAndNullUsageAndRetainsRowsAcrossCompactionAndArchive() async throws {
    let space = try makeSpace()
    let session = try await space.sessions.createSession(group: .shared, title: "coder", kind: .agent, tags: ["coder"], createdBy: "owner", model: .test)
    try await space.recordInference(record(session, id: "ok"))
    try await space.recordInference(record(session, id: "failed", failed: true))
    let expected: [[Cell]] = [
      [.text("failed"), .text(session.rawValue), .text("2023-11-14T22:13:20.000Z"), .text("codex"), .text("configured"), .null, .text("high"), .null, .null, .null, .null, .null, .text("timeout"), .text("idleTimeout"), .integer(1200), .null],
      [.text("ok"), .text(session.rawValue), .text("2023-11-14T22:13:20.000Z"), .text("codex"), .text("configured"), .text("served"), .text("high"), .integer(30), .integer(200), .integer(0), .integer(80), .integer(60), .text("ok"), .null, .integer(1200), .integer(100)],
    ]
    #expect(try await space.query("SELECT * FROM inferences ORDER BY id").rows == expected)
    _ = try await space.sessions.restart(session)
    _ = try await space.sessions.writeCompaction(session, head: .init(id: UUID(), timestamp: fixedDate, summary: "compact", snapshot: .init()), kept: nil)
    _ = try await space.sessions.archive(session, grace: .seconds(0))
    #expect(try await space.query("SELECT * FROM inferences ORDER BY id").rows == expected)
    #expect(try await space.query("SELECT sum(input), sum(cache_read), sum(output), sum(reasoning) FROM inferences JOIN sessions ON session = sessions.id WHERE sessions.tags LIKE '%coder%'").rows == [[.integer(30), .integer(200), .integer(80), .integer(60)]])
  }

  @Test func observationsWakeOnInsertion() async throws {
    let space = try makeSpace()
    let session = try await space.sessions.createSession(group: .shared, title: "coder", kind: .agent, createdBy: "owner", model: .test)
    let rows = Collector<Rows>()
    let stream = await space.observeQuery("SELECT count(*) FROM inferences", throttle: .zero)
    let consumer = Task { for try await value in stream { await rows.append(value) } }
    defer { consumer.cancel() }
    #expect(await awaitItems(rows, atLeast: 1).map(\.rows) == [[[.integer(0)]]])
    try await space.recordInference(record(session, id: "call"))
    #expect(await awaitItems(rows, atLeast: 2).map(\.rows) == [[[.integer(0)]], [[.integer(1)]]])
  }

  @Test func sameVisibilityAsSessionsIncludingQualifiedReadableGroups() async throws {
    let space = try makeSpace()
    let other = GroupID(rawValue: "other")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('other', '2026-09-30T00:00:00.000Z')")
    }
    let session = try await space.sessions.createSession(group: other, title: "hidden", kind: .agent, createdBy: "owner", model: .test)
    try await space.recordInference(record(session, id: "call"))
    #expect(try await space.query("SELECT * FROM inferences").rows.isEmpty)
    await #expect(throws: SpaceError.unknownRelation("wuhu://other.localspace/inferences")) {
      try await space.query("SELECT * FROM \"wuhu://other.localspace/inferences\"")
    }
    try await space.addEdge(src: .shared, dst: other, kind: .read, by: nil)
    #expect(try await space.query("SELECT session FROM \"wuhu://other.localspace/inferences\"").rows == [[.text(session.rawValue)]])
    #expect(try await space.query("SELECT grp, session FROM \"wuhu://*.localspace/inferences\"").rows == [[.text("other"), .text(session.rawValue)]])
    #expect(try await space.query("SELECT * FROM inferences").rows.isEmpty)
  }

  @Test func openingOlderDatabaseAddsTableWithoutBackfillAndReopeningPreservesRows() async throws {
    let space = try makeSpace()
    let session = try await space.sessions.createSession(group: .shared, title: "existing", kind: .agent, createdBy: "owner", model: .test)
    let path = await space.writer.path
    try await space.writer.write { db in try db.execute(sql: "DROP TABLE inferences") }
    let upgraded = try Space.open(file: URL(fileURLWithPath: path))
    #expect(try await upgraded.query("SELECT count(*) FROM inferences").rows == [[.integer(0)]])
    #expect(try await upgraded.query("SELECT id FROM sessions").rows == [[.text(session.rawValue)]])
    try await upgraded.recordInference(record(session, id: "new-call"))
    let reopened = try Space.open(file: URL(fileURLWithPath: path))
    #expect(try await reopened.query("SELECT id FROM inferences").rows == [[.text("new-call")]])
  }
}
