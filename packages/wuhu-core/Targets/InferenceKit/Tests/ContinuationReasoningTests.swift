import Dependencies
import Fetch
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import Synchronization
import Testing
import WuhuAI

@Suite struct ContinuationReasoningTests {
  @Test(arguments: [false, true])
  func noReplayScopeIsStillATypedErrorEvenAfterBoundary(carried: Bool) async throws {
    let executor = executor(scope: nil)
    let history = history(signed: false, carried: carried)
    await withReasoningDependencies {
      await #expect(throws: InferenceError.invalidInput(status: 400, body: "Anthropic thinking requires a verified replay scope; explicitly request reasoning none for a no-opaque route")) {
        try await executor.run(attemptID: UUID(), transcript: history, mode: .normal)
      }
    }
  }

  @Test func malformedCurrentTurnIsStillGuardedWithoutBoundary() async throws {
    await withReasoningDependencies {
      await #expect(throws: InferenceError.invalidInput(status: 400, body: "Anthropic thinking tool history requires signed thinking; the current tool-use assistant history has missing, unsigned or incompatible thinking")) {
        try await executor(scope: "scope").run(attemptID: UUID(), transcript: history(signed: false, carried: false), mode: .normal)
      }
    }
  }

  @Test func compactionPreservingSignedThinkingKeepsReasoningEnabled() async throws {
    let body = try await emittedRequest(history(signed: true, carried: true))
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
    #expect(body.jsonString().contains("signed-thinking"))
  }

  @Test func carriedUnsignedToolHistoryDisablesThinkingOnTheWire() async throws {
    let body = try await emittedRequest(history(signed: false, carried: true))
    #expect(body.object?["thinking"] == nil)
    #expect(body.object?["messages"]?.array?.contains { $0.object?["content"]?.array?.contains { $0.object?["type"]?.stringValue == "tool_use" } == true } == true)
  }

  @Test(arguments: [SystemNotification.Kind.timer, .spaceObservation, .context])
  func notificationStartsFreshReasoningTurn(kind: SystemNotification.Kind) async throws {
    var transcript = history(signed: false, carried: true)
    transcript.append(.notification(.init(id: UUID(), timestamp: Date(), kind: kind, subscriptionID: .init(kind == .context ? "cache-warming" : "trigger"), content: .init(text: "fresh input"))))
    let body = try await emittedRequest(transcript)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test(arguments: ["replay-handoff", "model-route", "legacy-handoff", "legacy-route", "empty-context"])
  func onlySyntheticBoundaryNoticesPreserveSuppression(source: String) async throws {
    var transcript = history(signed: false, carried: true)
    let text: String
    switch source {
    case "legacy-handoff": text = "Portable replay handoff completed. Earlier tool calls have their committed receipts; do not execute them again. This is a fresh account-neutral turn. Continue the outstanding request using the full carried input; re-read files/history as needed."
    case "legacy-route": text = "Model group work moved a → b (quota). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed."
    case "empty-context": text = ""
    default: text = "boundary continuation"
    }
    transcript.append(.notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init(source.hasPrefix("legacy-") || source == "empty-context" ? "context" : source), content: .init(text: text))))
    let body = try await emittedRequest(transcript)
    #expect(body.object?["thinking"] == nil)
  }

  private func emittedRequest(_ transcript: Transcript) async throws -> JSONValue {
    let bodies = Mutex<[JSONValue]>([])
    try await withDependencies {
      $0.continuousClock = ContinuousClock()
      $0.date = DateGenerator { Date() }
      $0.fetch = FetchClient { request in
        let body = try await request.body?.json(JSONValue.self) ?? .null
        bodies.withLock { $0.append(body) }
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"index":0,"delta":{"type":"text_delta","text":"done"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
      }
    } operation: {
      _ = try await executor(scope: "scope").run(attemptID: UUID(), transcript: transcript, mode: .normal)
    }
    return try #require(bodies.withLock { $0.first })
  }

  private func executor(scope: String?) -> InferenceExecutor {
    .init(session: .init("continuation-test"), model: .init(specifier: .init(provider: "testing", model: "m", effort: "high"), endpoint: AnthropicEndpoint(model: "m", replayScope: scope, baseURL: URL(string: "http://localhost:1")!, apiKey: "fake"), budget: .init(maxInput: 10000, maxOutput: 1000), replayScope: scope), systemPrompt: "test", tools: [])
  }

  private func history(signed: Bool, carried: Bool) -> Transcript {
    let call = ToolCall(id: "call", name: "read", arguments: .object([:]))
    let items: [TranscriptItem] = [
      .direct(.init(id: UUID(), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: .init(text: "test"))),
      .assistant(.init(id: UUID(), timestamp: Date(), content: (signed ? [.reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "reason", opaque: "signed-thinking", replayScope: "scope")))] : []) + [.toolCall(call)], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: ["call": .init("call")], replayBinding: .init(identity: "scope", epoch: "route"))),
      .toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init("call")), payload: .failure(.init(message: "receipt")))),
    ]
    return Transcript(items: items, keptCount: carried ? items.count : 0)
  }
}

private func withReasoningDependencies(_ operation: () async -> Void) async {
  await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
  } operation: {
    await operation()
  }
}
