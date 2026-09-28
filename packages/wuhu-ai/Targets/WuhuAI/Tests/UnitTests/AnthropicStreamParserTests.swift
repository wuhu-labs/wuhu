import Foundation
import Testing
@testable import WuhuAI

// MARK: - Anthropic Stream Parser Tests

@Suite struct AnthropicStreamParserTests {
  private func sse(_ events: [SSEEvent]) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  private func jsonEvent(_ event: String, _ dict: [String: Any]) -> SSEEvent {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
    return SSEEvent(
      event: event,
      data: String(data: data, encoding: .utf8)!,
    )
  }

  @Test func parsesSimpleTextStream() async throws {
    let events = [
      jsonEvent("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      jsonEvent("content_block_start", ["content_block": ["type": "text", "text": ""]]),
      jsonEvent("content_block_delta", ["delta": ["type": "text_delta", "text": "Hello"]]),
      jsonEvent("content_block_delta", ["delta": ["type": "text_delta", "text": " world"]]),
      jsonEvent("content_block_stop", ["index": 0]),
      jsonEvent("message_delta", ["delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 5]]),
      jsonEvent("message_stop", [:]),
    ]

    let stream = parseAnthropicStream(sse(events), providerID: "anthropic", model: "claude")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    // Check start event
    if case let .start(msg) = results.first {
      #expect(msg.content.isEmpty)
    }

    // Check final done event
    if case let .done(msg, metadata) = results.last {
      #expect(metadata.stopReason == .stop)
      let texts = msg.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(texts == "Hello world")
      #expect(metadata.usage?.inputTokens == 10)
      #expect(metadata.usage?.outputTokens == 5)
    }
  }

  @Test func parsesReasoningWithSignature() async throws {
    let events = [
      jsonEvent("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      jsonEvent("content_block_start", ["content_block": [
        "type": "thinking",
        "thinking": "Let me think",
        "signature": "sig_abc",
      ]]),
      jsonEvent("content_block_delta", ["delta": ["type": "thinking_delta", "thinking": " more"]]),
      jsonEvent("content_block_delta", ["delta": ["type": "signature_delta", "signature": "def"]]),
      jsonEvent("content_block_stop", ["index": 0]),
      jsonEvent("message_delta", ["delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 5]]),
      jsonEvent("message_stop", [:]),
    ]

    let stream = parseAnthropicStream(sse(events), providerID: "anthropic", model: "claude")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .encrypted(enc) = reasonings[0] {
        #expect(enc.summary == "Let me think more")
        #expect(enc.opaque == "sig_abcdef")
        #expect(enc.providerID == "anthropic")
        #expect(enc.model == "claude")
      } else {
        #expect(Bool(false), "Expected encrypted reasoning")
      }
    }
  }

  @Test func parsesRedactedThinking() async throws {
    let events = [
      jsonEvent("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      jsonEvent("content_block_start", ["content_block": [
        "type": "redacted_thinking",
        "data": "redacted_blob",
      ]]),
      jsonEvent("content_block_stop", ["index": 0]),
      jsonEvent("message_delta", ["delta": ["stop_reason": "end_turn"]]),
      jsonEvent("message_stop", [:]),
    ]

    let stream = parseAnthropicStream(sse(events), providerID: "anthropic", model: "claude")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .encrypted(enc) = reasonings[0] {
        #expect(enc.summary == nil)
        #expect(enc.opaque == "redacted_blob")
        #expect(enc.redacted == true)
      } else {
        #expect(Bool(false), "Expected encrypted reasoning")
      }
    }
  }

  @Test func parsesToolCalls() async throws {
    let events = [
      jsonEvent("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      jsonEvent("content_block_start", ["content_block": [
        "type": "tool_use",
        "id": "toolu_001",
        "name": "search",
        "input": [:],
      ]]),
      jsonEvent("content_block_delta", ["delta": [
        "type": "input_json_delta",
        "partial_json": #"{"query":"#,
      ]]),
      jsonEvent("content_block_delta", ["delta": [
        "type": "input_json_delta",
        "partial_json": #""test"}"#,
      ]]),
      jsonEvent("content_block_stop", ["index": 0]),
      jsonEvent("message_delta", ["delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 5]]),
      jsonEvent("message_stop", [:]),
    ]

    let stream = parseAnthropicStream(sse(events), providerID: "anthropic", model: "claude")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, metadata) = results.last {
      #expect(metadata.stopReason == .stop)
      let toolCalls = msg.content.compactMap { block -> ToolCall? in
        if case let .toolCall(tc) = block { return tc }
        return nil
      }
      #expect(toolCalls.count == 1)
      #expect(toolCalls[0].id == "toolu_001")
      #expect(toolCalls[0].name == "search")
      #expect(toolCalls[0].arguments.json.object?["query"] == .string("test"))
    }
  }

  @Test func emitsContentIndexEvents() async throws {
    let events = [
      jsonEvent("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      jsonEvent("content_block_start", ["content_block": ["type": "text", "text": ""]]),
      jsonEvent("content_block_delta", ["delta": ["type": "text_delta", "text": "Hi"]]),
      jsonEvent("content_block_stop", ["index": 0]),
      jsonEvent("message_delta", ["delta": ["stop_reason": "end_turn"]]),
      jsonEvent("message_stop", [:]),
    ]

    let stream = parseAnthropicStream(sse(events), providerID: "test", model: "m")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    // Should have textStart and textEnd with correct contentIndex
    let hasTextStart = results.contains { event in
      if case let .textStart(idx, _) = event { return idx == 0 }
      return false
    }
    #expect(hasTextStart)

    let hasTextEnd = results.contains { event in
      if case let .textEnd(idx, text, _) = event { return idx == 0 && text == "Hi" }
      return false
    }
    #expect(hasTextEnd)
  }

  @Test func throwsOnEOFBeforeMessageStop() async throws {
    let events = [
      jsonEvent("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      jsonEvent("content_block_start", ["content_block": ["type": "text", "text": ""]]),
      jsonEvent("content_block_delta", ["delta": ["type": "text_delta", "text": "Hi"]]),
      jsonEvent("content_block_stop", ["index": 0]),
      jsonEvent("message_delta", ["delta": ["stop_reason": "end_turn"]]),
    ]

    let stream = parseAnthropicStream(sse(events), providerID: "test", model: "m")
    do {
      for try await _ in stream {}
      Issue.record("Expected stream to throw")
    } catch let error as ProviderStreamError {
      #expect(error.type == "invalid_stream")
      #expect(error.message == "Anthropic stream ended before message_stop")
    }
  }
}
