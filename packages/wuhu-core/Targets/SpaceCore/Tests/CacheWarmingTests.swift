import Dependencies
import DeterministicDependencies
import Foundation
import Scratch
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing
import WuhuAI

private final class WarmingTime: Sendable {
  let value = Mutex(fixedDate)
  var now: Date { value.withLock { $0 } }
  func advance(_ seconds: Double = 3300) { value.withLock { $0.addTimeInterval(seconds) } }
}

@Suite(.deterministicDependencies) struct CacheWarmingTests {
  private func settle(_ store: SessionStore, _ id: SessionID, tokens: Int = 100_000) async throws {
    _ = try await store.drainQueue(id)
    try await store.appendAssistant(id, attemptID: UUID(), message: .init(content: []), metadata: .init(stopReason: .stop, usage: .init(inputTokens: tokens, outputTokens: 0, totalTokens: tokens)))
    try await store.scheduleCacheWarming(id, intervalSeconds: 3300)
  }

  private func ping(_ store: SessionStore, _ id: SessionID, quotaLow: Bool = false, max: Int = 20) async throws -> Bool {
    let pinged = try await store.enqueueCacheWarming(id, maxPings: max, floorTokens: 50000, images: .claude, quotaLow: quotaLow)
    try await store.deliverMail()
    return pinged
  }

  private func row(_ store: SessionStore, _ id: SessionID) async throws -> CacheWarmingRow? {
    try await store.writer.read { try CacheWarmingRow.where { $0.sessionID.eq(id.rawValue) }.fetchOne($0) }
  }

  @Test func twentyPingsEachOfferingCompactionThenStopUntilRealInput() async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let space = try Space.inMemory()
        let store = space.sessions
        let id = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
        try await settle(store, id)
        try await store.scheduleCacheWarming(id, intervalSeconds: 3300)
        #expect(try await !ping(store, id))
        for index in 0 ..< 20 {
          time.advance()
          #expect(try await ping(store, id))
          let notice = try #require(try await store.undrainedInputs(id).last?.input)
          #expect(notice.content.text.contains("<cache-warming-notice>"))
          #expect(notice.content.text.contains("compact tool now with park: true"), "ping \(index)")
          try await settle(store, id)
        }
        time.advance()
        #expect(try await !ping(store, id))
        #expect(try await store.notifications(recipient: "morgan").isEmpty)
        for input in [SessionFix.message(), SessionFix.notification()] {
          try await store.put(id, input: input)
          try await settle(store, id)
          #expect(try await !ping(store, id))
          time.advance()
          #expect(try await ping(store, id))
          try await settle(store, id)
        }
      }
    }
  }

  @Test func floorGatesWarmingWithoutSpendingPings() async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let store = try Space.inMemory().sessions
        let id = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
        try await settle(store, id, tokens: 49999)
        time.advance()
        let before = try #require(try await row(store, id))
        #expect(try await !ping(store, id, max: 1))
        let after = try #require(try await row(store, id))
        #expect(after.pingCount == before.pingCount && after.nextPingAt == before.nextPingAt)
        #expect(try await store.undrainedInputs(id).isEmpty)
        try await settle(store, id, tokens: 50000)
        time.advance()
        #expect(try await ping(store, id, max: 1))
        #expect(try await store.undrainedInputs(id).last?.input.content.text.contains("compact tool now with park: true") == true)
        _ = try await store.drainQueue(id)
        _ = try await store.writeCompaction(id, head: .init(id: UUID(), timestamp: time.now, summary: "folded", snapshot: .init(), runningWork: []), kept: nil)
        try await store.put(id, input: SessionFix.message("new work"))
        try await settle(store, id, tokens: 12000)
        time.advance()
        #expect(try await !ping(store, id, max: 1))
        try await settle(store, id, tokens: 60000)
        time.advance()
        #expect(try await ping(store, id, max: 1))
      }
    }
  }

  @Test func quotaStopsUntilRealInputAndTasksNeverWarm() async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let store = try Space.inMemory().sessions
        let agent = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
        let task = try await store.createSession(group: .shared, title: "Task", kind: .task, createdBy: "morgan", model: .test)
        for id in [agent, task] { try await settle(store, id); try await store.scheduleCacheWarming(id, intervalSeconds: 3300) }
        time.advance()
        #expect(try await !ping(store, agent, quotaLow: true))
        #expect(try await !ping(store, task))
        time.advance()
        #expect(try await !ping(store, agent))
        try await store.put(agent, input: SessionFix.notification())
        try await settle(store, agent)
        time.advance()
        #expect(try await ping(store, agent))
      }
    }
  }

  @Test func silentHandlerClaimsDoNotDelayWarmingOrResetPingBudget() async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let store = try Space.inMemory().sessions
        let helpers = ObserverRowsTests()
        let id = try await helpers.owner(store)
        try await settle(store, id)
        let slot = try await helpers.arm(store, id)
        for cycle in 0 ..< 2 {
          for tick in 0 ..< 110 {
            time.advance(30)
            let marker = "\(cycle)-\(tick)"
            let attempt = try await helpers.begin(store, slot, marker: marker)
            try await helpers.finish(store, attempt, .ok(wakes: []), .taken(marker: marker))
          }
          #expect(try await store.undrainedInputs(id).isEmpty)
          #expect(try await ping(store, id, max: 2))
          try await settle(store, id)
        }
        time.advance()
        let attempt = try await helpers.begin(store, slot, marker: "stopped")
        try await helpers.finish(store, attempt, .ok(wakes: []), .taken(marker: "stopped"))
        #expect(try await !ping(store, id, max: 2))
        let wake = try await helpers.begin(store, slot, marker: "wake")
        try await helpers.finish(store, wake, .ok(wakes: ["real input"]), .taken(marker: "wake"))
        try await settle(store, id)
        time.advance()
        #expect(try await ping(store, id, max: 2))
      }
    }
  }

  @Test func warmingCompactionPreservesBudgetUntilRealInputInference() async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let store = try Space.inMemory().sessions
        let id = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
        try await settle(store, id)
        for _ in 0 ..< 19 { time.advance(); #expect(try await ping(store, id)); try await settle(store, id) }
        time.advance()
        #expect(try await ping(store, id))
        _ = try await store.drainQueue(id)
        _ = try await store.writeCompaction(id, head: .init(id: UUID(), timestamp: time.now, summary: "folded", snapshot: .init(), runningWork: []), kept: nil)
        try await settle(store, id)
        time.advance()
        #expect(try await !ping(store, id))
        try await store.put(id, input: SessionFix.notification("real input"))
        try await settle(store, id)
        time.advance()
        #expect(try await ping(store, id))
      }
    }
  }

  @Test func warmingToolAndBookmarkContinuationsPreserveBudget() async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let store = try Space.inMemory().sessions
        let id = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
        try await settle(store, id)
        time.advance()
        #expect(try await ping(store, id, max: 1))
        _ = try await store.drainQueue(id)
        try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("", toolCalls: [.init(id: "warm-tool", name: "grep", arguments: .object([:]))]), metadata: SessionFix.metadata)
        let transcript = try await store.transcript(id)
        guard case let .assistant(entry) = try #require(transcript.items.last) else { Issue.record("missing warming assistant"); return }
        let call = try #require(entry.toolCallIDs["warm-tool"])
        try await store.writeToolResult(id, SessionFix.toolResult(callID: call.rawValue))
        try await store.writeBookmark(id, .init(id: UUID(), timestamp: time.now))
        try await settle(store, id)
        time.advance()
        #expect(try await !ping(store, id, max: 1))
        try await store.put(id, input: SessionFix.message("new work"))
        try await settle(store, id)
        time.advance()
        #expect(try await ping(store, id, max: 1))
      }
    }
  }

  @Test(arguments: [SystemNotification.Kind.owedReply, .parkReminder])
  func warmingAssistantAndNagBatchPreservesBudget(_ kind: SystemNotification.Kind) async throws {
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        let store = try Space.inMemory().sessions
        let id = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
        try await settle(store, id)
        time.advance()
        #expect(try await ping(store, id, max: 1))
        _ = try await store.drainQueue(id)
        var transcript = try await store.transcript(id)
        let before = transcript.items.count
        transcript.appendAssistant(.init(content: []), id: UUID(), metadata: SessionFix.metadata)
        transcript.append(.notification(.init(id: UUID(), timestamp: time.now, kind: kind, subscriptionID: .init("nag"), content: .init(text: "nag only"))))
        try await store.append(id, items: Array(transcript.items[before...]), inputOrigin: transcript.cacheWarmingInputOrigin)
        try await settle(store, id)
        time.advance()
        #expect(try await !ping(store, id, max: 1))
      }
    }
  }

  @Test func serverRestartPreservesBudgetButStartOverResetsIt() async throws {
    let folder = try ScratchFolder("warming-restart")
    let file = folder.url.appending(path: "space.sqlite")
    let time = WarmingTime()
    try await withSessionDeps {
      try await withDependencies { $0.date = DateGenerator { time.now } } operation: {
        func firstRun() async throws -> SessionID {
          let space = try Space.open(file: file)
          let store = space.sessions
          let id = try await store.createSession(group: .shared, title: "Warm", kind: .agent, createdBy: "morgan", model: .test)
          try await settle(store, id)
          try await store.scheduleCacheWarming(id, intervalSeconds: 3300)
          time.advance()
          #expect(try await ping(store, id, max: 2))
          try await settle(store, id)
          try await space.close()
          return id
        }
        let id = try await firstRun()
        time.advance(3300 * 12)
        let space = try Space.open(file: file)
        let store = space.sessions
        try await store.deferOverdueCacheWarming()
        #expect(try await !ping(store, id, max: 2))
        time.advance()
        #expect(try await ping(store, id, max: 2))
        #expect(try await store.undrainedInputs(id).last?.input.content.text.contains("compact tool now with park: true") == true)
        try await settle(store, id)
        time.advance()
        #expect(try await !ping(store, id, max: 2))
        _ = try await store.restart(id)
        try await settle(store, id)
        try await store.scheduleCacheWarming(id, intervalSeconds: 3300)
        time.advance()
        #expect(try await ping(store, id, max: 2))
        #expect(try await store.undrainedInputs(id).last?.input.content.text.contains("compact tool now with park: true") == true)
        try await store.put(id, input: SessionFix.notification("real after restart"))
        try await settle(store, id)
        time.advance()
        #expect(try await ping(store, id, max: 2))
        try await space.close()
      }
    }
  }
}
