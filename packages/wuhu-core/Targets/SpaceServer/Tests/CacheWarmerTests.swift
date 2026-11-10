import Dependencies
import DeterministicDependencies
import Foundation
import InferenceKit
import ModelProviders
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
        try await store.deliverMail()
        #expect(try await store.undrainedInputs(warm).last?.input.content.text.contains("<cache-warming-notice>") == true)
        for id in [disabled, task, neverRan] { #expect(try await store.undrainedInputs(id).isEmpty) }
        #expect(try await store.inbox("morgan").isEmpty)
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
        try await space.sessions.deliverMail()
        #expect(try await space.sessions.undrainedInputs(id).last?.input.content.text.contains("<cache-warming-notice>") == true)
        #expect(try await space.sessions.modelRoute(id) == route)
        usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 95, resetsAt: nil)], at: time.withLock { $0 })
        #expect(try await !warmer.allows(id))
        #expect(try await space.sessions.modelRoute(id) == route)
      }
    }
  }
}
