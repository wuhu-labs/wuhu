import Clocks
import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

struct SessionObserveTests {
  @Test func sessionsTableIsQueryableThroughTheSandbox() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let sid = try await space.sessions.createSession(group: .shared, title: "Build", kind: .agent, tags: ["ops"], createdBy: "morgan", model: .test)
      let rows = try await space.query("SELECT id, title, work, lifecycle FROM sessions")
      #expect(rows.rows == [[
        .text(sid.rawValue), .text("Build"), .text("no_work"), .text("live"),
      ]])
    }
  }

  @Test func sessionInternalTablesStayHidden() async throws {
    let space = try makeSpace()
    for table in ["session_queue", "session_contents", "session_pointers", "session_receipts", "session_runtime"] {
      await #expect(throws: SpaceError.self) {
        _ = try await space.query("SELECT * FROM \(table)")
      }
    }
  }

  @Test func sessionsObservableSnapshotThenCoarseTail() async throws {
    try await withSessionDeps {
      let clock = ImmediateClock()
      let space = try makeSpace(clock: clock)
      let store = space.sessions

      let results = Collector<Rows>()
      let stream = await space.observeQuery("SELECT work FROM sessions ORDER BY id", throttle: .zero)
      let consumer = Task { do { for try await rows in stream { await results.append(rows) } } catch {} }
      defer { consumer.cancel() }

      _ = await awaitItems(results, atLeast: 1)
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = await awaitItems(results, atLeast: 2)
      _ = try await store.enqueue(sid, input: SessionFix.message())
      let collected = await awaitItems(results, atLeast: 3)

      // Draining does not flip the axis, so the induced table stays silent:
      // per-item traffic never reaches observers.
      _ = try await store.drainQueue(sid)
      await settle()

      #expect(collected.count == 3)
      #expect(collected[0].rows.isEmpty)
      #expect(collected[1].rows == [[.text("no_work")]])
      #expect(collected[2].rows == [[.text("has_work")]])
      #expect(await results.items.count == 3)
    }
  }
}
