import Foundation
import Testing
@testable import WuhuAI

// MARK: - Gemini Stream Parser Tests

@Suite struct GeminiStreamParserTests {
  private func sse(_ events: [SSEEvent]) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  private func geminiChunk(_ dict: [String: Any]) -> SSEEvent {
    let data = try! JSONSerialization.data(withJSONObject: [dict], options: [])
    return SSEEvent(data: String(data: data, encoding: .utf8)!)
  }

  @Test func parsesSimpleTextStream() async throws {
    let events = [
      geminiChunk([
        "candidates": [[
          "content": [
            "role": "model",
            "parts": [["text": "Hello world"]],
          ],
          "finishReason": "STOP",
        ]],
        "usageMetadata": [
          "promptTokenCount": 10,
          "candidatesTokenCount": 5,
          "totalTokenCount": 15,
        ],
      ]),
    ]

    let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini-2.5-flash")
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

  @Test func parsesThoughtPart() async throws {
    let events = [
      geminiChunk([
        "candidates": [[
          "content": [
            "role": "model",
            "parts": [
              [
                "thought": true,
                "text": "Let me think",
                "thoughtSignature": "sig_123",
              ],
              ["text": "Answer"],
            ],
          ],
          "finishReason": "STOP",
        ]],
      ]),
    ]

    let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .encrypted(enc) = reasonings[0] {
        #expect(enc.summary == "Let me think")
        #expect(enc.opaque == "sig_123")
        #expect(enc.providerID == "gemini")
      } else {
        #expect(Bool(false), "Expected encrypted reasoning")
      }
    }
  }

  @Test func parsesFunctionCall() async throws {
    let events = [
      geminiChunk([
        "candidates": [[
          "content": [
            "role": "model",
            "parts": [[
              "functionCall": [
                "name": "search",
                "args": ["query": "test"],
              ],
            ]],
          ],
          "finishReason": "FUNCTION_CALL",
        ]],
      ]),
    ]

    let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini")
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
      #expect(toolCalls[0].arguments.json.object?["query"] == .string("test"))
    }
  }

  @Test func handlesThoughtSignatureOnTextPart() async throws {
    let events = [
      geminiChunk([
        "candidates": [[
          "content": [
            "role": "model",
            "parts": [[
              "text": "Answer",
              "thoughtSignature": "sig_abc",
            ]],
          ],
          "finishReason": "STOP",
        ]],
      ]),
    ]

    let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      // Should have a reasoning block (from thoughtSignature) before the text
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .encrypted(enc) = reasonings[0] {
        #expect(enc.opaque == "sig_abc")
        #expect(enc.summary == nil)
      } else {
        #expect(Bool(false), "Expected encrypted reasoning")
      }

      let texts = msg.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(texts == "Answer")
    }
  }

  @Test func mapsFinishReasons() async throws {
    let testCases: [(String, StopReason)] = [
      ("STOP", .stop),
      ("MAX_TOKENS", .maxTokens),
      ("SAFETY", .refusal),
      ("FUNCTION_CALL", .stop),
    ]

    for (reason, expected) in testCases {
      let events = [
        geminiChunk([
          "candidates": [[
            "content": ["role": "model", "parts": [["text": "x"]]],
            "finishReason": reason,
          ]],
        ]),
      ]
      let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini")
      var results: [InferenceEvent] = []
      for try await event in stream { results.append(event) }
      if case let .done(_, metadata) = results.last {
        #expect(metadata.stopReason == expected, "For finishReason: \(reason)")
      }
    }
  }

  @Test func emitsStartEvent() async throws {
    let events = [
      geminiChunk([
        "candidates": [[
          "content": ["role": "model", "parts": [["text": "Hi"]]],
          "finishReason": "STOP",
        ]],
      ]),
    ]
    let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini-2.5")
    var results: [InferenceEvent] = []
    for try await event in stream { results.append(event) }

    if case let .start(msg) = results.first {
      #expect(msg.content.isEmpty)
      #expect(msg.phase == nil)
    }
  }

  @Test func throwsOnEOFBeforeFinishReason() async throws {
    let events = [
      geminiChunk([
        "candidates": [[
          "content": ["role": "model", "parts": [["text": "Hi"]]],
        ]],
      ]),
    ]
    let stream = parseGeminiStream(sse(events), providerID: "gemini", model: "gemini-2.5")

    do {
      for try await _ in stream {}
      Issue.record("Expected stream to throw")
    } catch let error as ProviderStreamError {
      #expect(error.type == "invalid_stream")
      #expect(error.message == "Gemini stream ended before finishReason")
    }
  }
}
