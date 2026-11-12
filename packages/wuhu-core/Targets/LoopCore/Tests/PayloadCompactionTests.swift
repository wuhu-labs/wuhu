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
  @Test func repeatedOversizeErrorsAfterOneCompaction() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "oversize", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.failing(payloadError), Fix.failing(payloadError), Fix.replying("must not run")])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        try await service.enqueue(item: Fix.message("one gigantic item"), to: sid)
        try await until("payload permanently errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(try await sessions.generationState(sid).generation == 1)
      #expect(script.count == 2)
      #expect(try await sessions.record(sid).errorMessage == String(describing: compactedPayloadError))
      let lines = try await sessions.lines(sid)
      #expect(lines.assistantLines.isEmpty)
    }
  }

  @Test func aFreshGenerationTheProviderStillRefusesErrors() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "mixed payload", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.failing(payloadError), Fix.failing(.contextTooLong)])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("mixed payload errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(try await sessions.generationState(sid).generation == 1)
      #expect(script.count == 2)
      #expect(try await sessions.record(sid).errorMessage == String(describing: InferenceError.contextTooLong))
    }
  }

  @Test func successfulInferenceResetsPayloadCompactionBudget() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "payload reset", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.failing(payloadError), Fix.replying("first"), Fix.failing(payloadError), Fix.replying("second")])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        for round in 0 ..< 2 {
          try await service.enqueue(item: Fix.message("round \(round)"), to: sid)
          try await until("settled \(round)") { guard script.count == (round + 1) * 2 else { return false }; return try await sessions.settledWork(sid) }
        }
      }
      #expect(try await sessions.generationState(sid).generation == 2)
      #expect(try await sessions.record(sid).errorMessage == nil)
    }
  }

  @Test func actualWebSocketOverflowCompactsInvalidatesAndCommitsOnlyFreshReply() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "socket payload", kind: .agent, createdBy: "morgan", model: .test)
      let socket = ResponsesWebSocketSession()
      let endpoint = OpenAIGPTEndpoint(model: "test", baseURL: URL(string: "https://offline.test/v1")!, apiKey: "offline")
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
        let context = Context(systemPrompt: request.generation == 0 ? "original" : "compacted", messages: [.user(.init(content: [.text("retained")]))])
        let inference = endpoint.withWebSocket(session: socket, attemptID: request.attemptID.uuidString).inference(context: context)
        let message = try await inference.collect()
        return InferenceReply(message: message, metadata: Fix.reply("usage").metadata, committed: { _ in commits.withLock { $0 += 1 } })
      })
      config.invalidateInference = { _ in
        invalidations.withLock { $0 += 1 }
        await socket.invalidate()
      }
      try await withDependencies {
        $0[WebSocketConnector.self] = connector
        $0.fetch = FetchClient { _ in Issue.record("SSE fallback"); throw FetchError.unimplemented }
      } operation: {
        try await runService(space, config) { service in
          try await service.enqueue(item: Fix.message("hello"), to: sid)
          try await until("fresh reply committed") { guard commits.value == 1 else { return false }; return try await sessions.settledWork(sid) }
          #expect(invalidations.value == 1)
        }
      }
      #expect(dials.value == 2)
      #expect(try await sessions.generationState(sid).generation == 1)
      #expect(commits.value == 1)
      #expect(bodies.value.count == 2)
      #expect(bodies.value.allSatisfy { $0.object?["previous_response_id"] == nil })
      #expect(try await sessions.lines(sid).assistantLines.count == 1)
    }
  }
}
