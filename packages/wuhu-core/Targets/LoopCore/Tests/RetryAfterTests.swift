import Credentials
import Dependencies
import Fetch
import Foundation
import InferenceKit
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct RetryAfterTests {
  @Test func `a throttle carrying retryAt waits exactly until it, then succeeds`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.rateLimited(retryAt: anchor.addingTimeInterval(600))),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        try await time.asleep("retry-after", dueIn: 600)
        await time.advance(by: 599)
        try await holds("no retry before retryAt") { script.count == 1 }
        await time.advance(by: 1)
        try await until("attempt 2") { script.count == 2 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let offsets = script.attempts.value.map { $0.at.timeIntervalSince(anchor) }
      #expect(abs(offsets[1] - 600) < 0.001)
    }
  }

  @Test func `a retryAt beyond an hour is re-asked hourly`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let weekly = anchor.addingTimeInterval(5 * 3600)
      let script = InferenceScript([
        Fix.failing(.rateLimited(retryAt: weekly)),
        Fix.failing(.rateLimited(retryAt: weekly)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        try await time.wake("capped wait 1", after: retryAtCeiling)
        try await until("attempt 2") { script.count == 2 }
        try await time.wake("capped wait 2", after: retryAtCeiling)
        try await until("attempt 3") { script.count == 3 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let offsets = script.attempts.value.map { $0.at.timeIntervalSince(anchor) }
      #expect(abs(offsets[1] - 3600) < 0.001)
      #expect(abs(offsets[2] - 7200) < 0.001)
    }
  }

  // A backend repeating a stale reset time must not turn the loop into a
  // zero-delay hammer: a retryAt not in the future is the exponential step.
  @Test func `a retryAt not in the future backs off exponentially`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let stale = anchor.addingTimeInterval(-60)
      let rounds = 4
      let script = InferenceScript(
        Array(repeating: Fix.failing(.rateLimited(retryAt: stale)), count: rounds) + [Fix.replying("done")],
      )
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = (0 ..< rounds).map { attempt in
        min(backoffCeiling, pow(2.0, Double(attempt))) * Double.random(in: 0 ... 1, using: &rng)
      }

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.asleep("backoff \(index + 1)", dueIn: delay)
          await time.advance(by: delay * 0.5)
          try await holds("attempt count at \(index + 1) mid-backoff") { script.count == index + 1 }
          await time.advance(by: delay * 0.5)
        }
        try await until("final attempt") { script.count == rounds + 1 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let expected = delays.reduce(into: [0.0]) { acc, delay in acc.append(acc.last! + delay) }
      let offsets = script.attempts.value.map { $0.at.timeIntervalSince(anchor) }
      for (offset, expectedOffset) in zip(offsets, expected) {
        #expect(abs(offset - expectedOffset) < 0.001)
      }
    }
  }

  // The provider's wait draws no jitter and does not reset the count, so the
  // exponential schedule around it is the one a throttle without retryAt keeps.
  @Test func `a retryAt wait leaves the exponential schedule untouched`() async throws {
    try await withKernelDeps(seed: 7) { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.rateLimited(retryAt: nil)),
        Fix.failing(.rateLimited(retryAt: anchor.addingTimeInterval(900))),
        Fix.failing(.rateLimited(retryAt: nil)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let first = 1 * Double.random(in: 0 ... 1, using: &rng)
      let third = 4 * Double.random(in: 0 ... 1, using: &rng)

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        try await time.wake("backoff 1", after: first)
        try await until("attempt 2") { script.count == 2 }
        try await time.wake("retry-after", after: 900 - first)
        try await until("attempt 3") { script.count == 3 }
        try await time.wake("backoff 3", after: third)
        try await until("attempt 4") { script.count == 4 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let offsets = script.attempts.value.map { $0.at.timeIntervalSince(anchor) }
      #expect(abs(offsets[2] - 900) < 0.001)
      #expect(abs(offsets[3] - (900 + third)) < 0.001)
    }
  }

  @Test func `interrupt cancels a long retryAt wait and resume retries`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.rateLimited(retryAt: anchor.addingTimeInterval(retryAtCeiling))),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        try await time.asleep("retry-after", dueIn: retryAtCeiling)

        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .interrupted)
        #expect(time.sleeping(dueIn: retryAtCeiling) == 0)

        await time.advance(by: retryAtCeiling)
        try await holds("no retry while interrupted") { script.count == 1 }

        try await service.resume(sid)
        try await until("retry after resume") { script.count == 2 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }
    }
  }

  @Test func `a provider 429 with Retry-After is waited out end to end`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let document = ModelsDocument(providers: ["offline": .init(dialect: .anthropic, baseURL: URL(string: "https://example.test/v1")!, models: ["test": .init(maxInput: 1_001_000, maxOutput: 1000, efforts: ["low"], defaultEffort: "low")])])
      let resolved = try await ProviderCatalog(document: document, credentials: .init { _ in .apiKey("offline") }).resolve(.init(provider: "offline", model: "test", effort: "low"), session: sid)
      let executor = InferenceExecutor(session: sid, model: resolved, systemPrompt: "offline", tools: [])

      let calls = Box(0)
      let provider = FetchClient { _ in
        let call = calls.withLock { count -> Int in count += 1; return count }
        guard call > 1 else {
          return Response(status: .init(code: 429), headers: RequestHeaders(values: ["retry-after": "1800"]).fields, body: .string(#"{"type":"error","error":{"type":"rate_limit_error","message":"limited"}}"#))
        }
        return Response(status: .ok, body: .bytes(Data(textSSE.utf8), contentType: "text/event-stream"))
      }
      let step: InferenceScript.Step = { request in
        let completed = try await executor.run(attemptID: request.attemptID, transcript: request.transcript, mode: .normal)
        return InferenceReply(message: completed.message, metadata: completed.metadata)
      }
      let script = InferenceScript([step, step])
      let config = makeConfig(inference: { try await script($0) })

      try await withDependencies { $0.fetch = provider } operation: {
        try await runService(sessions, config) { service in
          _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
          try await until("throttled") { script.count == 1 }
          try await time.asleep("retry-after", dueIn: 1800)
          await time.advance(by: 1799)
          try await holds("no retry before Retry-After") { calls.value == 1 }
          await time.advance(by: 1)
          try await until("settled") { try await sessions.settledWork(sid) }
        }
      }

      #expect(calls.value == 2)
      let entries = try await sessions.hydrate(sid).transcript.kernel.assistantEntries
      #expect(entries.count == 1)
      #expect(abs(script.attempts.value[1].at.timeIntervalSince(anchor) - 1800) < 0.001)
    }
  }
}

private let textSSE = """
event: message_start
data: {"message":{"model":"claude-served","usage":{"input_tokens":10}}}

event: content_block_start
data: {"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"delta":{"type":"text_delta","text":"back"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {}

"""
