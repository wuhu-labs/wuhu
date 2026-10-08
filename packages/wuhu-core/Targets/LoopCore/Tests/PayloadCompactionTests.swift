import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchWebSocket
import InferenceKit
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

private let payloadError = InferenceError.requestTooLarge(limitBytes: 128 << 20)
private let compactedPayloadError = InferenceError.requestTooLargeAfterCompaction(limitBytes: 128 << 20)

@Suite struct PayloadCompactionTests {
  @Test(arguments: [false, true])
  func repeatedOversizeErrorsAfterOneCompactionEvenOnForcedTurn(forced: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "oversize", kind: .agent, createdBy: "morgan", model: .test)
      if forced { try await sessions.requestCommand(sid, .compact(instructions: nil)) }
      let script = InferenceScript([Fix.failing(payloadError), Fix.failing(payloadError), Fix.replying("must not run")])
      let compactions = Box(0)
      let config = makeConfig(inference: { try await script($0) }, compact: { transcript in
        compactions.withLock { $0 += 1 }
        let start: Int = if case .generationHead? = transcript.items.first { 1 } else { 0 }
        return .init(summary: "one gigantic retained item", kept: start ..< transcript.items.count)
      })
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("retain this item"), to: sid)
        try await until("payload permanently errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(compactions.value == 1)
      #expect(script.count == 2)
      #expect(try await sessions.record(sid).errorMessage == String(describing: compactedPayloadError))
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.isEmpty)
      #expect(transcript.items.contains { if case let .message(message) = $0 { message.content.text == "retain this item" } else { false } })
    }
  }

  @Test func unrelatedContextCompactionDoesNotResetPayloadBudget() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "mixed payload", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.failing(payloadError), Fix.failing(.contextTooLong), Fix.failing(payloadError)])
      let compactor = CompactScript(.init(summary: "folded"))
      try await runService(sessions, makeConfig(inference: { try await script($0) }, compact: { try await compactor($0) })) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("mixed payload errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(compactor.count.value == 2)
      #expect(script.count == 3)
      #expect(try await sessions.record(sid).errorMessage == String(describing: compactedPayloadError))
    }
  }

  @Test func oversizedCompactorIsTypedAndNeverLoops() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "oversized compactor", kind: .agent, createdBy: "morgan", model: .test)
      let compactions = Box(0)
      let script = InferenceScript([Fix.failing(payloadError)])
      let config = makeConfig(inference: { try await script($0) }, compact: { _ in
        compactions.withLock { $0 += 1 }
        throw payloadError
      })
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("oversized compactor errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(compactions.value == 1)
      #expect(script.count == 1)
      #expect(try await sessions.record(sid).errorMessage == String(describing: compactedPayloadError))
    }
  }

  @Test func successfulInferenceResetsPayloadCompactionBudget() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "payload reset", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.failing(payloadError), Fix.replying("first"), Fix.failing(payloadError), Fix.replying("second")])
      let compactor = CompactScript(.init(summary: "fits"))
      try await runService(sessions, makeConfig(inference: { try await script($0) }, compact: { try await compactor($0) })) { service in
        for round in 0 ..< 2 {
          _ = try await service.enqueue(item: Fix.message("round \(round)"), to: sid)
          try await until("settled \(round)") { guard script.count == (round + 1) * 2 else { return false }; return try await sessions.settledWork(sid) }
        }
      }
      #expect(compactor.count.value == 2)
      #expect(try await sessions.record(sid).errorMessage == nil)
    }
  }

  @Test func actualWebSocketOverflowCompactsInvalidatesAndCommitsOnlyFreshReply() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "socket payload", kind: .agent, createdBy: "morgan", model: .test)
      let socket = ResponsesWebSocketSession()
      let endpoint = OpenAIGPTEndpoint(model: "test", baseURL: URL(string: "https://offline.test/v1")!, apiKey: "offline")
      let compactions = Box(0)
      let dials = Box(0)
      let bodies = Box<[JSONValue]>([])
      let commits = Box(0)
      let invalidations = Box(0)
      let connector = WebSocketConnector { request in
        #expect(request.limits.outboundMessageBytes == 128 << 20)
        let dial = dials.withLock { $0 += 1; return $0 }
        let inbound = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
        return WebSocketConnection(inbound: .init(inbound.stream), send: { message in
          guard case let .text(text) = message, let value = JSONValue.parse(text) else { throw UnexpectedCall("expected text create") }
          bodies.withLock { $0.append(value) }
          if dial == 1 { throw WebSocketError.limitExceeded(.outboundMessage) }
          inbound.continuation.yield(.message(.text(#"{"type":"response.completed","response":{"id":"resp_fresh","status":"completed","usage":{"input_tokens":10,"output_tokens":0},"output":[]}}"#)))
        }, close: { _ in inbound.continuation.finish() }, abort: { inbound.continuation.finish() })
      }
      var config = makeConfig(inference: { request in
        let context = Context(systemPrompt: compactions.value == 0 ? "original" : "compacted", messages: [.user(.init(content: [.text("retained")]))])
        let inference = endpoint.withWebSocket(session: socket, attemptID: request.attemptID.uuidString).inference(context: context)
        let message = try await inference.collect()
        return InferenceReply(message: message, metadata: Fix.reply("usage").metadata, committed: { _, _ in commits.withLock { $0 += 1 } })
      }, compact: { transcript in
        #expect(transcript.assistantEntries.isEmpty)
        compactions.withLock { $0 += 1 }
        return .init(summary: "compacted")
      })
      config.invalidateInference = { _ in
        invalidations.withLock { $0 += 1 }
        await socket.invalidate()
      }
      try await withDependencies {
        $0[WebSocketConnector.self] = connector
        $0.fetch = FetchClient { _ in Issue.record("SSE fallback"); throw FetchError.unimplemented }
      } operation: {
        try await runService(sessions, config) { service in
          _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
          try await until("fresh reply committed") { guard commits.value == 1 else { return false }; return try await sessions.settledWork(sid) }
          #expect(invalidations.value == 1)
        }
      }
      #expect(dials.value == 2)
      #expect(compactions.value == 1)
      #expect(commits.value == 1)
      #expect(bodies.value.count == 2)
      #expect(bodies.value.allSatisfy { $0.object?["previous_response_id"] == nil })
      #expect(try await sessions.hydrate(sid).transcript.kernel.assistantEntries.count == 1)
    }
  }
}
