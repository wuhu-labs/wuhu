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
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "silent retirement", kind: .agent, createdBy: "morgan", model: .test)
      let timerID = SubscriptionID("timer.silent")
      let schedule = TimerSchedule.oneShot(anchor.addingTimeInterval(60))
      let slot = SubscriptionSlot(id: timerID, kind: .timer(schedule, message: "unused"), handler: "/silent.js")
      _ = try await sessions.armSubscription(id, slot: slot, nextFireAt: anchor.addingTimeInterval(60))
      _ = try await sessions.writeCompaction(id, head: .init(
        id: UUID(), timestamp: anchor, summary: "waiting", snapshot: .init(subscriptions: [timerID: .timer(schedule)]),
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
          #expect(text.contains("active subscriptions: none"))
          return Fix.reply("compact", calls: [.init(id: "compact", name: "compact", arguments: .object(["summary": "retired quietly"]))])
        },
        { request in
          #expect(request.transcript.environment.tools.subscriptions[timerID] == nil)
          return Fix.reply("done")
        },
      ])
      try await runService(sessions, makeConfig(inference: { try await script($0) })) { service in
        try await service.wake(id)
        try await until("loaded session settles") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(id)
        }
        let tail = try await sessions.queueHead(id)
        let armed = try #require(await sessions.armedSubscriptions(id).first)
        let incarnation = try #require(armed.slot.handlerIncarnation)
        let attempt = try #require(await sessions.beginSubscriptionHandler(
          id, subscriptionID: timerID, incarnation: incarnation,
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
      }
    }
  }

  @Test func afterACompactionEveryRequestListsTheWorkRunningAtThatMoment() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "running work", kind: .agent, createdBy: "morgan", model: .test)
      let running = Box<[String]>([])
      @Sendable func runningLine(_ request: InferenceRequest) async -> String? {
        let rendered = await request.transcript.renderRequest(session: id, systemPrompt: "test")
        return rendered.messages.compactMap(\.user).flatMap(\.content).compactMap { block -> String? in
          if case let .text(text) = block { return text.text }; return nil
        }.joined(separator: "\n").split(separator: "\n").first { $0.hasPrefix("running:") }.map(String.init)
      }
      let script = InferenceScript([
        { _ in Fix.reply("compact", calls: [.init(id: "compact", name: "compact", arguments: .object(["summary": "fresh"]))]) },
        { request in
          #expect(await runningLine(request) == "running: none")
          running.withLock { $0 = ["exec.ex_0a1b2c3d"] }
          return Fix.reply("started")
        },
        { request in
          #expect(await runningLine(request) == "running: exec.ex_0a1b2c3d")
          running.withLock { $0 = [] }
          return Fix.reply("still going")
        },
        { request in
          #expect(await runningLine(request) == "running: none")
          return Fix.reply("done")
        },
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.runningWork = { _ in running.value }
      try await runService(sessions, config) { service in
        for (text, count) in [("one", 2), ("two", 3), ("three", 4)] {
          _ = try await service.enqueue(item: Fix.message(text), to: id)
          try await until("request \(count) settles") {
            guard script.count == count else { return false }
            return try await sessions.settledWork(id)
          }
        }
      }
    }
  }

  @Test func afterStartOverTheFirstRequestListsTheWorkStillRunning() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
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
      config.runningWork = { session in
        #expect(session == id)
        return ["script.ffff0000", "exec.ex_0a1b2c3d"]
      }
      try await runService(sessions, config) { service in
        _ = try await service.restart(id, executor: nil, note: nil)
        _ = try await service.enqueue(item: Fix.message("what is still running?"), to: id)
        try await until("the fresh generation answers") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(id)
        }
      }
    }
  }
}
