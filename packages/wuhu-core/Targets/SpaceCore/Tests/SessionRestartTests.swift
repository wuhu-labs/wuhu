import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct SessionRestartTests {
  @Test func restartOpensAnEmptyGenerationAndKeepsTheIdentity() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(
        group: .shared,
        title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init(),
      )
      try await store.put(id, input: SessionFix.message("first"))
      _ = try await store.drainQueue(id)
      let restart = try await store.restart(id, note: "started over")
      #expect(restart.generation == 1)
      #expect(try await store.transcriptLines(id).map(\.key) == ["head", "head:note"])
      #expect(try await store.generationState(id).generation == 1)

      #expect(try await store.generationState(id).note == "started over")

      let record = try await store.record(id)
      #expect(record.id == id, "the id is the identity and survives a restart")
      #expect(record.title == "t")
      #expect(record.work == .noWork)
    }
  }

  @Test func restartKeepsQueuedWorkAndSubscriptionsAndClearsTheErrorAxis() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.armSubscription(
        id,
        slot: .init(id: .init("timer.t1"), kind: .timer(.oneShot(fixedDate), message: "wake")),
        nextFireAt: fixedDate.addingTimeInterval(60),
      )
      try await store.put(id, input: SessionFix.message("queued"))
      try await store.markErrored(id, message: "boom")
      try await store.deliverMail()
      try await store.markInterrupted(id)

      _ = try await store.restart(id)

      let hydration = try await store.hydrate(id)
      #expect(try await store.undrainedInputs(id).isEmpty)
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(try await store.transcriptLines(id).map(\.key).contains("message:m1"))
      #expect(hydration.record.work == .hasWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(hydration.record.hold == .normal)
      #expect(try await store.armedSubscriptions(id).count == 1)
      #expect(try await store.armedSubscriptions(id).first?.slot.kind == .timer(.oneShot(fixedDate), message: "wake"))
    }
  }

  @Test func restartPreservesRequestsAndQueuedInputs() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let parent = try await store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let task = try await store.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: "morgan", executor: .kernel(.test))
      _ = try await store.openRequest(on: task, from: .session(parent), messageID: .init("r1"), text: "existing duty")
      try await store.deliverMail()
      _ = try await store.drainQueue(task)
      try await store.markInterrupted(task)
      try await store.put(task, input: SessionFix.message("queued", message: "queued", owesReply: true))
      #expect(try await store.undrainedInputs(task).count == 1)
      _ = try await store.restart(task)
      let hydration = try await store.hydrate(task)
      #expect(try await store.undrainedInputs(task).isEmpty)
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(try store.openRequests(task).map(\.id) == [.init("r1")])
      let drained = try await store.drainQueue(task)
      #expect(drained.items.isEmpty)
      #expect(try await store.transcriptLines(task).last?.key == "message:queued")
      _ = try await store.report(task, request: .init("r1"), kind: .final, messageID: .init("f1"), text: "done")
      #expect(try store.openRequests(task).isEmpty)
      _ = try await store.openRequest(on: task, from: .session(parent), messageID: .init("r2"), text: "new duty")
      _ = try await store.drainQueue(task)
      #expect(try store.openRequests(task).map(\.id) == [.init("r2")])
      _ = try await store.report(task, request: .init("r2"), kind: .final, messageID: .init("f2"), text: "done again")
      #expect(try store.openRequests(task).isEmpty)
    }
  }

  @Test func queueIdsStayMonotonicAcrossARestart() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      #expect(try await store.put(id, input: SessionFix.message("one")) == 1)
      try await store.markInterrupted(id)
      _ = try await store.restart(id)
      #expect(
        try await store.put(id, input: SessionFix.message("two")) == 2,
        "preserved rows keep ids monotonic under a live daemon cursor",
      )
      #expect(try await store.undrainedInputs(id).count == 1)
      #expect(try await store.transcriptLines(id).map(\.key).contains("message:m1"))
    }
  }

  @Test func bareRestartKeepsSubscriptionsAndClearsErrors() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let observation = try await store.armSubscription(id, slot: .init(id: .init("obs.keep"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30)), marker: "old snapshot")
      try await store.markErrored(id, message: "boom")
      try await store.deliverMail()
      _ = try await store.restart(id)
      let hydration = try await store.hydrate(id)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(try await store.armedSubscriptions(id) == [observation])
      #expect(try await store.armedSubscriptions(id).first?.slot.kind == .observe(sql: "SELECT 1", throttleSeconds: 30))
    }
  }

  @Test func corruptQueuedInputBetweenReadableInputsIsDroppedWithoutReorderingOrDuplicatingThem() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "recovery", kind: .agent, createdBy: "morgan", model: .test)
      let first = SessionFix.message("first", message: "first")
      let bad = SessionFix.message("bad", message: "bad")
      let last = SessionFix.message("last", message: "last")
      try await store.put(id, input: first)
      try await store.put(id, input: bad)
      try await store.put(id, input: last)
      try await store.space.plant("UPDATE session_queue SET payload = '{}' WHERE session_id = ? AND id = 2", arguments: [id.rawValue])
      try await store.markErrored(id, message: "unreadable queue")
      try await store.deliverMail()
      _ = try await store.restart(id, note: "Started over.")
      let hydration = try await store.hydrate(id)
      let undrained = try await store.undrainedInputs(id)
      #expect(undrained.isEmpty)
      #expect(hydration.queueTail == 5)
      #expect(hydration.record.errorMessage == nil)
      #expect(hydration.record.work == .hasWork)
      #expect(try await store.generationState(id).note == "Started over.\nDropped 1 queued input(s) that could not be read.")
      #expect(try await store.put(id, input: first) == 4)
      #expect(try await store.put(id, input: last) == 5)
      #expect(try await store.transcriptLines(id).map(\.key).filter { $0.hasPrefix("message:") } == ["message:first", "message:last"])
      #expect(try await store.drainQueue(id).items.isEmpty)
    }
  }

  @Test func unreadableQueuedDateIsReportedAndDoesNotWakeOrPreventArchive() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "date recovery", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(id, input: SessionFix.message("bad date"))
      try await store.space.plant("UPDATE session_queue SET enqueued_at = 'oops' WHERE session_id = ?", arguments: [id.rawValue])
      try await store.markErrored(id, message: "invalid date")
      try await store.deliverMail()
      _ = try await store.restart(id)
      let hydration = try await store.hydrate(id)
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(hydration.queueTail == hydration.queueHead)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(try await store.generationState(id).note == "Dropped 1 queued input(s) that could not be read.")
      _ = try await store.archive(id, grace: .seconds(60))
    }
  }

  @Test func restartIsRefusedWhileTheSessionIsArchived() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.archive(id, grace: .seconds(60))
      await #expect(throws: SessionStoreError.restartOfArchivedSession(id.rawValue)) {
        _ = try await store.restart(id)
      }
    }
  }
}
