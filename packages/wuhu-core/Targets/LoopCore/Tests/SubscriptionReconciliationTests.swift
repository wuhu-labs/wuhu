import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct SubscriptionReconciliationTests {
  @Test func silentRetirementDoesNotWakeLoadedSessionAndNextInferenceAndCompactionReconcile() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "silent retirement", kind: .agent, createdBy: "morgan", model: .test)
      let timerID = SubscriptionID("timer.silent")
      let schedule = TimerSchedule.oneShot(anchor.addingTimeInterval(60))
      let slot = SubscriptionSlot(id: timerID, kind: .timer(schedule, message: "unused"), handler: "/silent.js")
      _ = try await sessions.armSubscription(id, slot: slot, nextFireAt: anchor.addingTimeInterval(60))
      _ = try await sessions.writeCompaction(id, head: .init(
        id: UUID(), timestamp: anchor, summary: "waiting", snapshot: .init(subscriptions: [timerID: .timer(schedule)]),
        runningWork: [],
      ), kept: nil)
      let script = InferenceScript([
        { request in
          #expect(request.transcript.environment.tools.subscriptions[timerID] == .timer(schedule))
          return Fix.reply("idle")
        },
        { request in
          #expect(request.transcript.environment.tools.subscriptions[timerID] == nil)
          let rendered = await request.transcript.renderRequest(session: id, systemPrompt: "test")
          let text = rendered.messages.compactMap(\.user).flatMap(\.content).compactMap { block -> String? in
            if case let .text(text) = block { return text.text }; return nil
          }.joined(separator: "\n")
          #expect(text.contains("active subscriptions: timer.silent"))
          return Fix.reply("compact", calls: [.init(id: "compact", name: "compact", arguments: .object(["summary": "retired quietly"]))])
        },
        { request in
          #expect(request.transcript.environment.tools.subscriptions[timerID] == nil)
          return Fix.reply("done")
        },
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.runningWork = { _ in ["exec.snapshot"] }
      try await runService(space, config) { service in
        try await service.wake(id)
        try await until("loaded session settles") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(id)
        }
        let tail = try await sessions.queueHead(id)
        let armed = try #require(await sessions.armedSubscriptions(id).first)
        let incarnation = try #require(armed.slot.handlerIncarnation)
        let attempt = try #require(await sessions.beginSubscriptionHandler(
          .session(id), subscriptionID: timerID, incarnation: incarnation,
        ))
        #expect(try await sessions.finishSubscriptionHandler(attempt, result: .success(stateJSON: "null", advance: .retire, wakes: [])))
        #expect(try await sessions.queueHead(id) == tail)
        try await holds("silent retirement remains idle") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(id)
        }
        _ = try await service.enqueue(item: Fix.message("next unrelated work"), to: id)
        try await until("compacted generation settles") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(id)
        }
        let transcript = try await sessions.hydrate(id).transcript.kernel
        #expect(transcript.environment.tools.subscriptions[timerID] == nil)
        guard case let .generationHead(head)? = transcript.items.first else {
          Issue.record("expected compacted head"); return
        }
        #expect(head.snapshot.subscriptions[timerID] == nil)
        #expect(head.runningWork == ["exec.snapshot"])
      }
    }
  }

  @Test func afterStartOverTheFirstRequestListsTheWorkStillRunning() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "running work", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        { request in
          let rendered = await request.transcript.renderRequest(session: id, systemPrompt: "test")
          let text = rendered.messages.compactMap(\.user).flatMap(\.content).compactMap { block -> String? in
            if case let .text(text) = block { return text.text }; return nil
          }.joined(separator: "\n")
          #expect(text.contains("running: exec.ex_0a1b2c3d, script.ffff0000"))
          return Fix.reply("done")
        },
      ])
      var config = makeConfig(inference: { try await script($0) })
      let running = Box(["script.ffff0000", "exec.ex_0a1b2c3d"])
      config.runningWork = { session in
        #expect(session == id)
        return running.value
      }
      try await runService(space, config) { service in
        _ = try await service.restart(id, executor: nil, note: nil)
        running.withLock { $0 = [] }
        _ = try await service.enqueue(item: Fix.message("what is still running?"), to: id)
        try await until("the fresh generation answers") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(id)
        }
      }
    }
  }
}
