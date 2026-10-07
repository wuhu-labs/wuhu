import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

struct SessionRestartTests {
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
      #expect(head.summary.isEmpty, "a restart carries no summary; it is not a compaction")
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

  @Test func restartDropsUndrainedWorkAndSubscriptionsAndClearsTheErrorAxis() async throws {
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

      _ = try await store.restart(id)

      let hydration = try await store.hydrate(id)
      #expect(hydration.undrained.isEmpty, "undrained rows never reach the fresh generation")
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(hydration.record.work == .noWork)
      #expect(hydration.record.errorMessage == nil)
      #expect(hydration.record.hold == .normal)
      #expect(try await store.armedSubscriptions(id).isEmpty, "timers and observations do not survive")
      #expect(hydration.transcript.kernel.items.count == 1)
      #expect(!hydration.transcript.kernel.hasWork)
    }
  }

  @Test func restartCarriesHealthySettleStateAndRetiresQueuedInputs() async throws {
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
      #expect(hydration.undrained.isEmpty)
      #expect(hydration.queueHead == hydration.queueTail)
      #expect(hydration.transcript.kernel.items.count == 1)
      #expect(hydration.transcript.kernel.environment.settle.openRequests[.init("r1")] != nil)
      #expect(hydration.transcript.kernel.environment.settle.owedConversations.contains(.init("ch1")))
      #expect(hydration.transcript.kernel.environment.settle == (try await store.settleState(task)))
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
        "a restart retires rows by advancing the tail; ids never rewind under a live daemon cursor",
      )
      let hydration = try await store.hydrate(id)
      #expect(hydration.undrained.count == 1)
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
