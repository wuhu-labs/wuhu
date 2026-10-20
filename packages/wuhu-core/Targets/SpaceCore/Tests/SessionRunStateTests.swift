import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing
import WuhuAI

// The sessions row says what the loop is doing, and its activity
// time follows the loop rather than only inputs and verbs.
@Suite(.deterministicDependencies)
struct SessionRunStateTests {
  private struct RunRow: Equatable {
    var work: String
    var run: String
    var progress: String?
    var activity: String
  }

  private final class Clock: Sendable {
    let now = Mutex(fixedDate)
    func advance() -> String {
      now.withLock {
        $0 = $0.addingTimeInterval(60)
        return SQLiteDateFormat.string(from: $0)
      }
    }
  }

  private func row(_ store: SessionStore, _ id: SessionID) async throws -> RunRow {
    try await store.writer.read { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT work, run_state, run_progress_at, last_activity_at FROM sessions WHERE id = ?", arguments: [id.rawValue],
      )!
      return RunRow(work: row["work"], run: row["run_state"], progress: row["run_progress_at"], activity: row["last_activity_at"])
    }
  }

  private func expectRow(_ store: SessionStore, _ id: SessionID, _ expected: RunRow, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let actual = try await row(store, id)
    #expect(actual == expected, sourceLocation: sourceLocation)
  }

  private func withMovingDate<T>(_ body: (Clock) async throws -> T) async rethrows -> T {
    let clock = Clock()
    return try await withDependencies {
      $0.uuid = .incrementing
      $0.date = DateGenerator { clock.now.withLock { $0 } }
    } operation: {
      try await body(clock)
    }
  }

  @Test func runStateFollowsInferenceAndToolCallsAndStampsActivity() async throws {
    try await withMovingDate { clock in
      let store = try Space.inMemory().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message())
      #expect(try await row(store, sid).run == "no_run")

      var at = clock.advance()
      _ = try await store.drainQueue(sid)
      try await expectRow(store, sid, RunRow(work: "has_work", run: "inference", progress: at, activity: at))

      at = clock.advance()
      let call = ToolCall(id: "call_0", name: "exec", arguments: .object([:]))
      try await store.appendAssistant(sid, attemptID: UUID(), message: SessionFix.assistant("on it", toolCalls: [call]), metadata: SessionFix.metadata)
      let waiting = RunRow(work: "has_work", run: "tool", progress: at, activity: at)
      try await expectRow(store, sid, waiting)

      // A tool that takes its time does not move the row.
      _ = clock.advance()
      #expect(try await store.bootSessions() == [sid])
      try await expectRow(store, sid, waiting)

      at = clock.advance()
      let minted = try #require(try await store.transcript(sid).pendingToolCallIDs.first)
      try await store.writeToolResult(sid, SessionFix.toolResult(callID: minted.rawValue))
      try await expectRow(store, sid, RunRow(work: "has_work", run: "inference", progress: at, activity: at))

      at = clock.advance()
      try await store.appendAssistant(sid, attemptID: UUID(), message: SessionFix.assistant("done"), metadata: SessionFix.metadata)
      try await expectRow(store, sid, RunRow(work: "no_work", run: "no_run", progress: nil, activity: at))
    }
  }

  @Test func interruptErrorAndArchiveStopTheRunAndResumeRederivesIt() async throws {
    try await withMovingDate { clock in
      let store = try Space.inMemory().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message())
      _ = try await store.drainQueue(sid)
      let call = ToolCall(id: "call_0", name: "exec", arguments: .object([:]))
      try await store.appendAssistant(sid, attemptID: UUID(), message: SessionFix.assistant("on it", toolCalls: [call]), metadata: SessionFix.metadata)

      var at = clock.advance()
      try await store.markInterrupted(sid)
      try await expectRow(store, sid, RunRow(work: "has_work", run: "no_run", progress: nil, activity: at))

      at = clock.advance()
      try await store.markResumed(sid)
      try await expectRow(store, sid, RunRow(work: "has_work", run: "tool", progress: at, activity: at))

      at = clock.advance()
      try await store.markErrored(sid, message: "boom")
      try await expectRow(store, sid, RunRow(work: "errored", run: "no_run", progress: nil, activity: at))

      at = clock.advance()
      try await store.markResumed(sid)
      try await expectRow(store, sid, RunRow(work: "has_work", run: "tool", progress: at, activity: at))

      at = clock.advance()
      _ = try await store.archive(sid, grace: .seconds(3600))
      try await expectRow(store, sid, RunRow(work: "has_work", run: "no_run", progress: nil, activity: at))
    }
  }

  @Test func drainingWhileHeldOrErroredDoesNotStartARun() async throws {
    try await withMovingDate { _ in
      let store = try Space.inMemory().sessions
      let held = try await store.createSession(group: .shared, title: "held", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(held, input: SessionFix.message())
      try await store.markInterrupted(held)
      _ = try await store.drainQueue(held)
      #expect(try await row(store, held).run == "no_run")

      let errored = try await store.createSession(group: .shared, title: "errored", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(errored, input: SessionFix.message())
      try await store.markErrored(errored, message: "boom")
      _ = try await store.drainQueue(errored)
      #expect(try await row(store, errored).run == "no_run")
    }
  }
}
