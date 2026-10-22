import Dependencies
import DeterministicDependencies
import Foundation
import InferenceKit
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct CacheWarmerTests {
  @Test func onlyExplicitlyOptedInIdleAgentsReceiveOrdinaryNotices() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 100))
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.withLock { $0 } } } operation: {
        let space = try Space.inMemory()
        var document = try ModelsDocument(json: Data(testModelsJSON.utf8))
        var enabled = try #require(document.providers["testing"]?.models["test-model"])
        enabled.cacheWarming = CacheWarmingPolicy(floorTokens: 1)
        document.providers["testing"]?.models["warm-model"] = enabled
        _ = try await space.fs(.settings).write("/models.json", JSONEncoder().encode(document), ifMatch: nil)
        let warmer = CacheWarmer(space: space, usage: UsageBoard())
        let store = space.sessions
        let warm = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .init(provider: "testing", model: "warm-model", effort: "high"))
        let disabled = try await store.createSession(group: .shared, title: "Disabled", kind: .agent, createdBy: "morgan", model: .init(provider: "testing", model: "test-model", effort: "high"))
        let task = try await store.createSession(group: .shared, title: "Task", kind: .task, createdBy: "morgan", model: .init(provider: "testing", model: "warm-model", effort: "high"))
        let neverRan = try await store.createSession(group: .shared, title: "New", kind: .agent, createdBy: "morgan", model: .init(provider: "testing", model: "warm-model", effort: "high"))
        for id in [warm, disabled, task] {
          try await store.appendAssistant(id, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 0, totalTokens: 10)))
        }
        await warmer.tick()
        time.withLock { $0.addTimeInterval(3300) }
        await warmer.tick()
        #expect(try await store.hydrate(warm).undrained.last?.input.content.text.contains("<cache-warming-notice>") == true)
        for id in [disabled, task, neverRan] { #expect(try await store.hydrate(id).undrained.isEmpty) }
        #expect(try await store.notifications(recipient: "morgan").isEmpty)
      }
    }
  }

  @Test(arguments: ["removed", "removed-pressure", "restart", "quota", "task", "compacted", "raised-floor"])
  func ineligiblePersistedNoticeDoesNotRunInference(_ reason: String) async throws {
    try await withSessionDeps {
      let calls = Mutex(0)
      let usage = UsageBoard()
      let harness = try await SessionHarness(
        cacheWarmingUsage: usage,
        inference: { _, _ in calls.withLock { $0 += 1 }; return reply("real input only") },
      )
      var document = try ModelsDocument(json: Data(testModelsJSON.utf8))
      var enabled = try #require(document.providers["testing"]?.models["test-model"])
      enabled.cacheWarming = CacheWarmingPolicy(floorTokens: 50000)
      document.providers["testing"]?.models["warm-model"] = enabled
      let (head, _) = try await harness.space.fs(.settings).read("/models.json")
      _ = try await harness.space.fs(.settings).write("/models.json", JSONEncoder().encode(document), ifMatch: head)
      let id = try await harness.store.createSession(group: .shared, title: "Recovered", kind: reason == "task" ? .task : .agent, createdBy: "morgan", model: .init(provider: "testing", model: "warm-model", effort: "high"))
      try await harness.store.appendAssistant(id, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 60000, outputTokens: 0, totalTokens: 60000)))
      _ = try await harness.store.enqueue(id, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init("cache-warming"), content: .init(text: "<cache-warming-notice>ignore</cache-warming-notice>"))))
      if reason == "restart" {
        try await harness.store.markInterrupted(id)
        _ = try await harness.store.restart(id, executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      } else {
        if reason == "compacted" {
          _ = try await harness.store.writeCompaction(id, head: .init(id: UUID(), timestamp: Date(), summary: "folded", snapshot: .init(), runningWork: []), kept: nil)
          try await harness.store.appendAssistant(id, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 5000, outputTokens: 0, totalTokens: 5000)))
        }
        _ = try await harness.store.drainQueue(id)
      }
      if reason == "removed-pressure" {
        var transcript = try await harness.store.transcript(id)
        let pressure = TranscriptItem.notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init("context-pressure"), content: .init(text: "<compaction-notice>Context is 80% full. Compact at a natural boundary.</compaction-notice>")))
        transcript.append(pressure)
        try await harness.store.append(id, items: [pressure], inputOrigin: transcript.cacheWarmingInputOrigin)
        try await harness.store.markInterrupted(id)
        try await harness.store.markResumed(id)
      }
      if reason == "removed" || reason == "removed-pressure" || reason == "raised-floor" {
        document.providers["testing"]?.models["warm-model"]?.cacheWarming = reason == "raised-floor" ? CacheWarmingPolicy(floorTokens: 60001) : nil
        let (head, _) = try await harness.space.fs(.settings).read("/models.json")
        _ = try await harness.space.fs(.settings).write("/models.json", JSONEncoder().encode(document), ifMatch: head)
      }
      if reason == "quota" { usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 95, resetsAt: nil)], at: Date()) }
      try await harness.running {
        func settled() async throws {
          let updates = await harness.space.observeQuery("SELECT work FROM sessions WHERE id = '\(id.rawValue)'", throttle: .zero, as: .shared(.anonymous))
          for try await _ in updates {
            if try await harness.store.record(id).work == .noWork { break }
          }
        }
        try await settled()
        #expect(calls.withLock { $0 } == 0)
        let transcript = try await harness.store.transcript(id)
        #expect(!transcript.hasPendingCacheWarming)
        let context = await transcript.renderRequest(session: id, systemPrompt: "sys")
        let rendered = String(decoding: try JSONEncoder().encode(context.messages), as: UTF8.self)
        #expect(!rendered.contains("cache-warming-notice"))
        #expect(!rendered.contains("compaction-notice"))
        _ = try await harness.store.enqueue(id, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("real"), content: .init(text: "real input"))))
        try await settled()
        #expect(calls.withLock { $0 } == 1)
      }
    }
  }

  @Test func quotaUsesSameBoardAsProvidersAndOnlyCurrentFiveHourWindow() async throws {
    try await withSessionDeps {
      let now = Date()
      let board = UsageBoard()
      let warmer = CacheWarmer(space: try Space.inMemory(), usage: board)
      let policy = CacheWarmingPolicy()
      #expect(!warmer.quotaLow(provider: "p", policy: policy))
      board.record("p", plan: nil, windows: [.init(name: "seven_day", usedPercent: 100, resetsAt: nil)], at: now)
      #expect(!warmer.quotaLow(provider: "p", policy: policy))
      board.record("p", plan: nil, windows: [.init(name: "five_hour", usedPercent: 89.9, resetsAt: nil)], at: now)
      #expect(!warmer.quotaLow(provider: "p", policy: policy))
      board.record("p", plan: nil, windows: [.init(name: "five_hour", usedPercent: 90, resetsAt: nil)], at: now)
      #expect(warmer.quotaLow(provider: "p", policy: policy))
      board.record("p", plan: nil, windows: [.init(name: "five_hour", usedPercent: 100, resetsAt: now.addingTimeInterval(-60).timeIntervalSince1970)], at: now)
      #expect(!warmer.quotaLow(provider: "p", policy: policy))
      board.record("p", plan: nil, windows: [.init(name: "five_hour", usedPercent: nil, resetsAt: nil)], at: now)
      #expect(!warmer.quotaLow(provider: "p", policy: policy))
    }
  }
}

extension CacheWarmerTests {
  @Test func groupWarmingUsesPersistedMemberPolicyAndQuotaWithoutRepicking() async throws {
    let time = Mutex(Date(timeIntervalSince1970: 100))
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.withLock { $0 } } } operation: {
        let space = try Space.inMemory()
        var document = try ModelsDocument(json: Data(testModelsJSON.utf8))
        document.providers["testing"]!.models["test-model"]!.cacheWarming = CacheWarmingPolicy(floorTokens: 1)
        document.providers["alternate"] = document.providers["testing"]
        let group = ModelsDocument.Group(members: [
          .init(id: "held", provider: "testing", model: "test-model"),
          .init(id: "preferred", provider: "alternate", model: "test-model"),
        ], defaultEffort: "high", policy: .select(member: "preferred"))
        _ = try await space.fs(.settings).write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: nil)
        _ = try await space.fs(.settings).write(ModelsDocument.groupPath, JSONEncoder().encode(["work": group]), ifMatch: nil)
        let route = SessionModelRoute(group: "work", member: "held", specifier: .init(provider: "testing", model: "test-model", effort: "high"), bindingFingerprint: document.providers["testing"]!.routeFingerprint, epoch: "held-route", reason: .create, placedAt: time.withLock { $0 }, evidence: [])
        let id = try await space.sessions.createSession(group: .shared, title: "Pinned warmer", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: route)
        try await space.sessions.appendAssistant(id, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 0, totalTokens: 10)))
        let usage = UsageBoard()
        usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 100, resetsAt: nil)], at: time.withLock { $0 })
        let warmer = CacheWarmer(space: space, usage: usage)
        #expect(try await warmer.allows(id))
        await warmer.tick()
        time.withLock { $0.addTimeInterval(3300) }
        await warmer.tick()
        #expect(try await space.sessions.hydrate(id).undrained.last?.input.content.text.contains("<cache-warming-notice>") == true)
        #expect(try await space.sessions.modelRoute(id) == route)
        usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 95, resetsAt: nil)], at: time.withLock { $0 })
        #expect(try await !warmer.allows(id))
        #expect(try await space.sessions.modelRoute(id) == route)
      }
    }
  }
}
