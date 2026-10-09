import Dependencies
import Foundation
import GRDB
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct SessionRestartTests {
  @Test func restartOpensAnEmptyGenerationAndKeepsTheIdentity() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(
        group: .shared,
        title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init(),
      )
      _ = try await store.enqueue(id, input: SessionFix.message("first"))
      _ = try await store.drainQueue(id)
      _ = try await store.appendAssistant(
        id, attemptID: UUID(), message: SessionFix.assistant("done"), metadata: SessionFix.metadata,
      )
      #expect(try await store.transcript(id).items.count == 3)

      let restart = try await store.restart(id, note: "started over")
      #expect(restart.generation == 1)
      #expect(try await store.generationState(id).generation == 1)

      let transcript = try await store.transcript(id)
      #expect(transcript.items.count == 1, "the head is the whole of a restarted generation")
      guard case let .generationHead(head) = transcript.items[0] else {
        Issue.record("a restarted generation opens with its head, got \(transcript.items[0])")
        return
      }
      #expect(head.summary.isEmpty, "Start over is an empty-summary compaction")
      #expect(head.snapshot == StateSnapshot())
      #expect(head.note == "started over")
      #expect(transcript.keptCount == 1)
      #expect(!transcript.hasWork, "the note is context, not a prompt: nothing to answer")
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
      _ = try await store.enqueue(id, input: SessionFix.message("queued"))
      try await store.markErrored(id, message: "boom")
      try await store.markInterrupted(id)

      var signals = store.workSignals().makeAsyncIterator()
      _ = try await store.restart(id)
      #expect(await signals.next() == id)

      let hydration = try await store.hydrate(id)
      #expect(hydration.undrained.count == 1)
      #expect(hydration.queueHead > hydration.queueTail)
      #expect(hydration.record.work == .hasWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(hydration.record.hold == .normal)
      #expect(try await store.armedSubscriptions(id).count == 1)
      #expect(hydration.transcript.kernel.environment.tools.subscriptions[.init("timer.t1")] == .timer(.oneShot(fixedDate)))
      #expect(hydration.transcript.kernel.items.count == 1)
      #expect(!hydration.transcript.kernel.hasWork)
    }
  }

  @Test func restartCarriesHealthySettleStateAndPreservesQueuedInputs() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let parent = try await store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let task = try await store.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: "morgan", executor: .kernel(.test))
      _ = try await store.openRequest(on: task, from: parent, messageID: .init("r1"), text: "existing duty", deadline: nil)
      _ = try await store.drainQueue(task)
      _ = try await store.enqueue(task, input: SessionFix.message("queued", message: "queued", owesReply: true))
      try await store.markInterrupted(task)
      let before = try await store.hydrate(task)
      #expect(before.undrained.count == 1)
      _ = try await store.restart(task)
      let hydration = try await store.hydrate(task)
      #expect(hydration.undrained.count == 1)
      #expect(hydration.queueHead > hydration.queueTail)
      #expect(hydration.transcript.kernel.items.count == 1)
      #expect(hydration.transcript.kernel.environment.settle.openRequests[.init("r1")] != nil)
      #expect(!hydration.transcript.kernel.environment.settle.owedConversations.contains(.init("ch1")))
      #expect(hydration.transcript.kernel.environment.settle == (try await store.settleState(task)))
      let drained = try await store.drainQueue(task)
      #expect(drained.items.count == 1)
      #expect(try await store.transcript(task).environment.settle.owedConversations.contains(.init("ch1")))
      _ = try await store.report(task, request: .init("r1"), kind: .final, messageID: .init("f1"), text: "done")
      #expect(try await store.settleState(task).openRequests.isEmpty)
      _ = try await store.openRequest(on: task, from: parent, messageID: .init("r2"), text: "new duty", deadline: nil)
      _ = try await store.drainQueue(task)
      #expect(try await store.settleState(task).openRequests[.init("r2")] != nil)
      _ = try await store.report(task, request: .init("r2"), kind: .final, messageID: .init("f2"), text: "done again")
      #expect(try await store.settleState(task).openRequests.isEmpty)
    }
  }

  @Test func queueIdsStayMonotonicAcrossARestart() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      #expect(try await store.enqueue(id, input: SessionFix.message("one")) == 1)
      try await store.markInterrupted(id)
      _ = try await store.restart(id)
      #expect(
        try await store.enqueue(id, input: SessionFix.message("two")) == 2,
        "preserved rows keep ids monotonic under a live daemon cursor",
      )
      let hydration = try await store.hydrate(id)
      #expect(hydration.undrained.count == 2)
    }
  }

  @Test func bareRestartKeepsSubscriptionsButClearsParkRemindersAndErrors() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let observation = try await store.armSubscription(id, slot: .init(id: .init("obs.keep"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30)), marker: "old snapshot")
      _ = try await store.armSubscription(id, slot: .init(id: .park(.init("retry")), kind: .parkReminder(request: .init("retry"))), nextFireAt: fixedDate.addingTimeInterval(60))
      try await store.markErrored(id, message: "boom")
      try await store.requestCommand(id, .compact(instructions: "discard this"))
      _ = try await store.restart(id)
      #expect(try await store.pendingCommand(id) == nil)
      let hydration = try await store.hydrate(id)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(try await store.armedSubscriptions(id) == [observation])
      #expect(!hydration.transcript.kernel.hasWork)
      #expect(hydration.transcript.kernel.environment.tools.subscriptions == [.init("obs.keep"): .observe(sql: "SELECT 1")])
    }
  }

  @Test func malformedDeadlineRefusesRestartWithATypedError() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.armSubscription(id, slot: .init(id: .init("deadline.invalid"), kind: .requestDeadline(request: .init("r"), task: .init("child"))))
      await #expect(throws: SessionStoreError.requestDeadlineWithoutFireDate("deadline.invalid")) { _ = try await store.restart(id) }
      #expect(try await store.generationState(id).generation == 0)
    }
  }

  @Test func corruptQueuedInputBetweenReadableInputsIsDroppedWithoutReorderingOrDuplicatingThem() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "recovery", kind: .agent, createdBy: "morgan", model: .test)
      let first = SessionFix.message("first", message: "first")
      let bad = SessionFix.message("bad", message: "bad")
      let last = SessionFix.message("last", message: "last")
      _ = try await store.enqueue(id, input: first)
      _ = try await store.enqueue(id, input: bad)
      _ = try await store.enqueue(id, input: last)
      try await store.writer.write { db in
        try db.execute(sql: "UPDATE session_queue SET payload = '{}' WHERE session_id = ? AND id = 2", arguments: [id.rawValue])
      }
      try await store.markErrored(id, message: "unreadable queue")
      _ = try await store.restart(id, note: "Started over.")
      let hydration = try await store.hydrate(id)
      #expect(hydration.undrained.map(\.input) == [first, last])
      #expect(hydration.undrained.map(\.id) == [4, 5])
      #expect(hydration.queueTail == 3)
      #expect(hydration.record.errorMessage == nil)
      #expect(hydration.record.work == .hasWork)
      #expect(try await store.generationState(id).note == "Started over.\nDropped 1 queued input(s) that could not be read.")
      #expect(try await store.enqueue(id, input: first) == 4)
      #expect(try await store.enqueue(id, input: last) == 5)
      #expect(try await store.drainQueue(id).items == [first.transcriptItem, last.transcriptItem])
      #expect(try await store.drainQueue(id).items.isEmpty)
      let unreadable = try await store.writer.read { db in
        try String.fetchOne(db, sql: "SELECT payload FROM session_queue WHERE session_id = ? AND id = 2", arguments: [id.rawValue])
      }
      #expect(unreadable == "{}")
    }
  }

  @Test(arguments: ["enqueued_at", "drained_at"])
  func unreadableQueuedDateIsReportedAndDoesNotWakeOrPreventArchive(column: String) async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "date recovery", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(id, input: SessionFix.message("bad date"))
      try await store.writer.write { db in
        try db.execute(sql: "UPDATE session_queue SET \(column) = 'oops' WHERE session_id = ?", arguments: [id.rawValue])
      }
      try await store.markErrored(id, message: "invalid date")
      _ = try await store.restart(id)
      let hydration = try await store.hydrate(id)
      #expect(hydration.undrained.isEmpty)
      #expect(hydration.queueTail == hydration.queueHead)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(try await store.generationState(id).note == "Dropped 1 queued input(s) that could not be read.")
      _ = try await store.archive(id, grace: .seconds(60))
    }
  }

  @Test func restartResetsOpenRequestParkPacingWithoutClosingTheRequest() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let parent = try await store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      let task = try await store.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: "morgan", executor: .kernel(.test))
      _ = try await store.openRequest(on: task, from: parent, messageID: .init("parked"), text: "still owed", deadline: fixedDate.addingTimeInterval(3600))
      _ = try await store.drainQueue(task)
      for _ in 0 ..< 3 {
        _ = try await store.enqueue(task, input: .notification(.init(id: UUID(), timestamp: fixedDate, kind: .parkReminder, subscriptionID: .park(.init("parked")), requestID: .init("parked"), content: .init(text: "park reminder"))))
      }
      _ = try await store.drainQueue(task)
      let before = try #require(await store.settleState(task).openRequests[.init("parked")])
      #expect(before.parkReminderCount == 3)
      #expect(before.lastParkReminderAt == fixedDate)
      try await store.markInterrupted(task)
      _ = try await store.restart(task)
      let after = try #require(await store.settleState(task).openRequests[.init("parked")])
      var expected = before
      expected.parkReminderCount = 0
      expected.lastParkReminderAt = nil
      #expect(after == expected)
      #expect(try await store.transcript(task).environment.settle.openRequests[.init("parked")] == expected)
      #expect(ParkBackoff.nextFire(after: after, now: fixedDate) == fixedDate)
    }
  }

  @Test func restartIsRefusedWhileWorkIsOutstanding() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(id, input: SessionFix.message("queued"))
      await #expect(throws: SessionStoreError.busyForRestart(id.rawValue)) {
        _ = try await store.restart(id)
      }
      #expect(try await store.generationState(id).generation == 0, "a refused restart moves nothing")
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

  @Test func restartSwitchesTheExecutor() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let claude = ModelSpecifier(provider: "claude", model: "opus", effort: "high")

      let switched = try await store.restart(id, executor: .claudeCode(claude))
      #expect(switched.executor == .claudeCode(claude))
      #expect(try await store.record(id).executor == switched.executor)

      let back = try await store.restart(id, executor: .kernel(.test))
      #expect(back.executor == .kernel(.test))
      #expect(back.generation == 2)
    }
  }
}
