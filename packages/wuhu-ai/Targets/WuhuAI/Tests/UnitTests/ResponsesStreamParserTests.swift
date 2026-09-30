import Foundation
import JSONValue
import Testing
@testable import WuhuAI

// MARK: - Responses Stream Parser Tests

private enum ResponsesUsageProbeFailure: Error { case streamDidNotComplete }

@Suite struct ResponsesStreamParserTests {
  private func sse(_ events: [SSEEvent]) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  private func jsonEvent(_ dict: [String: Any]) -> SSEEvent {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
    return SSEEvent(data: String(data: data, encoding: .utf8)!)
  }

  @Test func parsesSimpleTextStream() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "message", "id": "msg_1", "role": "assistant",
        "content": [],
      ]]),
      jsonEvent(["type": "response.output_text.delta", "delta": "Hello"]),
      jsonEvent(["type": "response.output_text.delta", "delta": " world"]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "message", "id": "msg_1",
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

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

  @Test func parsesFunctionCall() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "function_call",
        "call_id": "call_1",
        "id": "item_1",
        "name": "search",
        "arguments": "",
      ]]),
      jsonEvent(["type": "response.function_call_arguments.delta", "delta": #"{"query":"#]),
      jsonEvent(["type": "response.function_call_arguments.delta", "delta": #""test"}"#]),
      jsonEvent(["type": "response.function_call_arguments.done", "arguments": #"{"query":"test"}"#]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "function_call", "call_id": "call_1", "name": "search",
        "arguments": #"{"query":"test"}"#,
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, metadata) = results.last {
      #expect(metadata.stopReason == .stop)
      let toolCalls = msg.content.compactMap { block -> ToolCall? in
        if case let .toolCall(tc) = block { return tc }
        return nil
      }
      #expect(toolCalls.count == 1)
      #expect(toolCalls[0].name == "search")
      // Only the `call_id` is persisted; the output-item `id` is dropped.
      #expect(toolCalls[0].id == "call_1")
      #expect(toolCalls[0].arguments.json.object?["query"] == .string("test"))
    }
  }

  @Test func parsesReasoningItem() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "reasoning",
        "id": "rs_1",
        "encrypted_content": "enc_blob_streamed",
        "summary": [["type": "summary_text", "text": "Let me think"]],
      ]]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "reasoning", "id": "rs_1",
        "encrypted_content": "enc_blob_done",
        "summary": [["type": "summary_text", "text": "Let me think deeply"]],
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .encrypted(enc) = reasonings[0] {
        #expect(enc.summary == "Let me think deeply")
        #expect(enc.opaque == "enc_blob_done")
        #expect(enc.id == "rs_1")
        #expect(enc.providerID == "openai")
      } else {
        #expect(Bool(false), "Expected encrypted reasoning")
      }
    }
  }

  @Test func preservesStreamedReasoningFieldsWhenDoneOmitsThem() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "reasoning",
        "id": "rs_1",
        "encrypted_content": "streamed_blob",
        "summary": [["type": "summary_text", "text": "streamed summary"]],
      ]]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "reasoning",
        "id": "rs_1",
        "summary": [],
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.5")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    guard case let .done(msg, _) = results.last,
          case let .reasoning(.encrypted(enc)) = msg.content.only
    else {
      Issue.record("Expected one encrypted reasoning block")
      return
    }

    #expect(enc.opaque == "streamed_blob")
    #expect(enc.summary == "streamed summary")
  }

  @Test func dropsEmptyReasoningItemFromFinalMessage() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "reasoning",
        "id": "rs_empty",
        "summary": [],
      ]]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "reasoning", "id": "rs_empty",
        "summary": [],
      ]]),
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "message", "id": "msg_1", "role": "assistant",
        "content": [],
      ]]),
      jsonEvent(["type": "response.output_text.delta", "delta": "answer"]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "message", "id": "msg_1",
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai-codex", model: "gpt-5.5")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      #expect(msg.content == [.text(.init(text: "answer"))])
    }
  }

  @Test func parsesPhaseMetadata() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "message", "id": "msg_1", "phase": "commentary",
        "content": [],
      ]]),
      jsonEvent(["type": "response.output_text.delta", "delta": "thinking..."]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "message", "id": "msg_1", "phase": "commentary",
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      #expect(msg.phase == .commentary)
    }
  }

  private func parsedUsage(_ usage: [String: Any]) async throws -> Usage {
    let events = [
      jsonEvent(["type": "response.output_text.delta", "delta": "hi"]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": usage,
      ]]),
    ]
    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.5")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }
    guard case let .done(_, metadata) = results.last else {
      throw ResponsesUsageProbeFailure.streamDidNotComplete
    }
    return try #require(metadata.usage)
  }

  @Test func readsNestedResponsesUsageDetails() async throws {
    let usage = try await parsedUsage([
      "input_tokens": 2444,
      "input_tokens_details": ["cached_tokens": 2304, "cache_write_tokens": 140],
      "output_tokens": 332,
      "output_tokens_details": ["reasoning_tokens": 128],
      "total_tokens": 2776,
    ])
    #expect(usage.inputTokens == 2444)
    #expect(usage.outputTokens == 332)
    #expect(usage.cacheReadTokens == 2304)
    #expect(usage.cacheWriteTokens == 140)
    #expect(usage.reasoningTokens == 128)
    #expect(usage.totalTokens == 2776)
  }

  @Test func fallsBackToFlatUsageKeys() async throws {
    let usage = try await parsedUsage([
      "input_tokens": 2444,
      "output_tokens": 332,
      "total_tokens": 2776,
      "cached_input_tokens": 2304,
      "cache_creation_input_tokens": 140,
      "reasoning_tokens": 128,
    ])
    #expect(usage.cacheReadTokens == 2304)
    #expect(usage.cacheWriteTokens == 140)
    #expect(usage.reasoningTokens == 128)
  }

  @Test func nestedUsageKeysWinOverFlatOnes() async throws {
    let usage = try await parsedUsage([
      "input_tokens": 2444,
      "input_tokens_details": ["cached_tokens": 2304],
      "output_tokens": 332,
      "output_tokens_details": ["reasoning_tokens": 128],
      "total_tokens": 2776,
      "cached_input_tokens": 7,
      "reasoning_tokens": 9,
    ])
    #expect(usage.cacheReadTokens == 2304)
    #expect(usage.reasoningTokens == 128)
  }

  @Test func absentUsageDetailsLeaveReasoningUnknown() async throws {
    let usage = try await parsedUsage([
      "input_tokens": 10,
      "output_tokens": 5,
      "total_tokens": 15,
    ])
    #expect(usage.cacheReadTokens == 0)
    #expect(usage.cacheWriteTokens == 0)
    #expect(usage.reasoningTokens == nil)
  }

  @Test func handlesErrorResponse() async throws {
    let events = [
      jsonEvent(["type": "response.failed", "response": ["status": "failed"]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    do {
      for try await _ in stream {}
      Issue.record("Expected stream to throw")
    } catch {
      // Expected — response.failed now throws
    }
  }

  @Test func throwsOnEOFBeforeResponseCompleted() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "message", "id": "msg_1", "role": "assistant",
        "content": [],
      ]]),
      jsonEvent(["type": "response.output_text.delta", "delta": "Hello"]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "message", "id": "msg_1",
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    do {
      for try await _ in stream {}
      Issue.record("Expected stream to throw")
    } catch let error as ProviderStreamError {
      #expect(error.type == "invalid_stream")
      #expect(error.message == "Responses stream ended before response.completed")
    }
  }
}

private extension Collection {
  var only: Element? {
    count == 1 ? first : nil
  }
}

extension ResponsesStreamParserTests {
  @Test func ingestsHostedWebSearchWithDigest() async throws {
    let payload = #"{ "id":"ws_1", "type":"web_search_call", "status":"completed", "action":{ "url":"https://example.com", "type":"open_page" } }"#
    let events = [
      SSEEvent(data: #"{"type":"response.output_item.done","item":\#(payload)}"#),
      SSEEvent(data: #"{"type":"response.completed","response":{"status":"completed"}}"#),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "codex", model: "gpt-5.6-sol")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    guard case let .done(message, _) = results.last,
          case let .hostedTool(item) = message.content.only
    else {
      Issue.record("Expected one hosted tool block")
      return
    }
    #expect(item.providerID == "codex")
    #expect(item.payload == JSONValue.parse(payload))
    #expect(item.type == "web_search_call")
    #expect(item.action == "open_page")
    #expect(item.digest == "web_search_call · open_page")
  }
}
