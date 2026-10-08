import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

private let malformedMessage = InferenceError.malformedModelMessage(message: "The model sent a malformed tool_use block.", reason: "invalid_tool_use_name")

@Suite struct MalformedMessageRetryTests {
  @Test(arguments: [false, true])
  func thirdFailureErrorsWithoutCompaction(forced: Bool) async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "malformed", kind: .agent, createdBy: "morgan", model: .test)
      if forced { try await sessions.requestCommand(sid, .compact(instructions: nil)) }
      let script = InferenceScript(Array(repeating: Fix.failing(malformedMessage), count: 4))
      let compactions = Box(0)
      let config = makeConfig(inference: { try await script($0) }, compact: { _ in
        compactions.withLock { $0 += 1 }
        return .init(summary: "must not run")
      })
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = [1.0, 2.0].map { $0 * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("retry \(index + 1)", after: delay)
        }
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      let record = try await sessions.record(sid)
      #expect(record.errorMessage == String(describing: malformedMessage))
      #expect(script.count == 3)
      #expect(script.attempts.value.allSatisfy { $0.mode == (forced ? .forcedCompact : .normal) })
      #expect(Set(script.attempts.value.map(\.itemCount)).count == 1)
      #expect(try await sessions.hydrate(sid).transcript.kernel.assistantEntries.isEmpty)
      #expect(compactions.value == 0)
    }
  }

  @Test func successfulInferenceResetsMalformedBudget() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "reset", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.failing(malformedMessage), Fix.failing(malformedMessage), Fix.replying("first"),
        Fix.failing(malformedMessage), Fix.failing(malformedMessage), Fix.replying("second"),
      ])
      let config = makeConfig(inference: { try await script($0) })
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = [1.0, 2.0, 1.0, 2.0].map { $0 * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, config) { service in
        for round in 0 ..< 2 {
          _ = try await service.enqueue(item: Fix.message("round \(round)"), to: sid)
          for index in 0 ..< 2 {
            try await until("failure \(round)-\(index)") { script.count == round * 3 + index + 1 }
            try await time.wake("retry \(round)-\(index)", after: delays[round * 2 + index])
          }
          try await until("settled \(round)") {
            guard script.count == (round + 1) * 3 else { return false }
            return try await sessions.settledWork(sid)
          }
        }
      }
      #expect(script.count == 6)
      let entries = try await sessions.hydrate(sid).transcript.kernel.assistantEntries
      #expect(entries.map(\.id) == [script.attempts.value[2].id, script.attempts.value[5].id])
    }
  }

  @Test func outageDoesNotResetMalformedBudget() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "outage", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.failing(malformedMessage), Fix.failing(.rateLimited(retryAt: nil)),
        Fix.failing(malformedMessage), Fix.failing(malformedMessage),
      ])
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = [1.0, 2.0, 4.0].map { $0 * Double.random(in: 0 ... 1, using: &rng) }
      try await runService(sessions, makeConfig(inference: { try await script($0) })) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for (index, delay) in delays.enumerated() {
          try await until("attempt \(index + 1)") { script.count == index + 1 }
          try await time.wake("retry \(index + 1)", after: delay)
        }
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 4)
      #expect(try await sessions.record(sid).errorMessage == String(describing: malformedMessage))
    }
  }

  @Test func failedStreamCommitsNoPartialTextOrToolCalls() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "partial", kind: .agent, createdBy: "morgan", model: .test)
      let document = ModelsDocument(providers: ["offline": .init(dialect: .responses, baseURL: URL(string: "https://example.test/v1")!, models: ["test": .init(maxInput: 1_001_000, maxOutput: 1000, efforts: ["low"], defaultEffort: "low")])])
      let resolved = try await ProviderCatalog(document: document, credentials: .init { _ in .apiKey("offline") }).resolve(.init(provider: "offline", model: "test", effort: "low"), session: sid)
      let hub = AttemptHub()
      let executor = InferenceExecutor(session: sid, model: resolved, systemPrompt: "offline", tools: [], hub: hub)
      let requests = Box<[JSONValue]>([])
      let commits = Box<[UUID]>([])
      let provider = FetchClient { request in
        let body = try await request.body?.json(JSONValue.self) ?? .null
        let number = requests.withLock { $0.append(body); return $0.count }
        let sse = number <= 2 ? failedSSE : successfulSSE
        return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
      }
      let step: InferenceScript.Step = { request in
        let result = try await executor.run(attemptID: request.attemptID, transcript: request.transcript, mode: .normal)
        return InferenceReply(message: result.message, metadata: result.metadata, committed: { entry, _ in commits.withLock { $0.append(entry.id) } })
      }
      let script = InferenceScript([step, step, step])
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delays = [1.0, 2.0].map { $0 * Double.random(in: 0 ... 1, using: &rng) }
      try await withDependencies { $0.fetch = provider } operation: {
        try await runService(sessions, makeConfig(inference: { try await script($0) })) { service in
          _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
          for (index, delay) in delays.enumerated() {
            try await until("failed attempt \(index + 1)") { script.count == index + 1 }
            try await time.asleep("retry \(index + 1)", dueIn: delay)
            #expect(hub.inFlight(session: sid).isEmpty)
            #expect(try await sessions.hydrate(sid).transcript.kernel.assistantEntries.isEmpty)
            #expect(commits.value.isEmpty)
            try await time.wake("retry \(index + 1)", after: delay)
          }
          try await until("settled") { try await sessions.settledWork(sid) }
        }
      }
      #expect(requests.value.count == 3)
      #expect(requests.value[0] == requests.value[1] && requests.value[1] == requests.value[2])
      #expect(commits.value == [script.attempts.value[2].id])
      let entries = try await sessions.hydrate(sid).transcript.kernel.assistantEntries
      #expect(entries.count == 1)
      #expect(entries[0].content == [.text(TextContent(text: "done"))])
    }
  }
}

private let failedSSE = """
data: {"type":"response.output_item.added","item":{"type":"message","id":"msg"}}

data: {"type":"response.output_text.delta","delta":"discard me"}

data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc","call_id":"bad_call","name":"must_not_execute","arguments":"{}"}}

data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc","call_id":"bad_call","name":"must_not_execute","arguments":"{}"}}

data: {"type":"response.failed","response":{"status":"failed","error":{"code":"malformed_model_message","message":"The model sent a malformed tool_use block.","reason":"invalid_tool_use_name"}}}

"""

private let successfulSSE = """
data: {"type":"response.output_item.added","item":{"type":"message","id":"msg"}}

data: {"type":"response.output_text.delta","delta":"done"}

data: {"type":"response.output_item.done","item":{"type":"message","id":"msg"}}

data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":1}}}

"""
