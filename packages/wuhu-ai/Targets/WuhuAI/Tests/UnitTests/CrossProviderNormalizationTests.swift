import Foundation
import JSONValue
import Testing
@testable import WuhuAI

// MARK: - Normalization Tests

@Suite struct CrossProviderNormalizationTests {
  // MARK: Tool Call ID Normalization

  @Test func passesValidToolCallIdThrough() {
    // Provider-native IDs are already valid → returned unchanged (preserves
    // prompt-cache prefixes and same-provider replay).
    #expect(wireToolCallID("call_abc123") == "call_abc123")
    #expect(wireToolCallID("toolu_01F5KVDnMyUWKyTeikK11oCQ") == "toolu_01F5KVDnMyUWKyTeikK11oCQ")
    #expect(wireToolCallID("call_ABC-123") == "call_ABC-123")
  }

  @Test func rewritesCompoundToolCallIdToHash() {
    // Legacy compound `call_id|item_id` contains `|`, which is invalid → hashed.
    let result = wireToolCallID("call_abc123|fc_xyz789")
    #expect(result.hasPrefix("wuhu_"))
    #expect(!result.contains("|"))
    #expect(isValidWireID(result))
  }

  @Test func rewritesUnsafeCharsToHash() {
    let result = wireToolCallID("call+abc/123=xyz")
    #expect(result.hasPrefix("wuhu_"))
    #expect(isValidWireID(result))
  }

  @Test func rewritesOverlongToolCallIdToHash() {
    // Over the 64-char cap → hashed (not truncated: truncation would risk
    // collisions and break call/result pairing).
    let long = String(repeating: "a", count: 100)
    let result = wireToolCallID(long)
    #expect(result.hasPrefix("wuhu_"))
    #expect(result.utf8.count <= 64)
    #expect(isValidWireID(result))
  }

  @Test func mapsToolCallIdDeterministically() {
    // Same input → same output (cache stability); distinct inputs → distinct.
    #expect(wireToolCallID("a|b") == wireToolCallID("a|b"))
    #expect(wireToolCallID("call_1|fc_1") != wireToolCallID("call_2|fc_2"))
  }

  @Test func wireToolCallIdIsIdempotent() {
    let once = wireToolCallID("call+abc/123=xyz")
    #expect(wireToolCallID(once) == once)
  }

  // Mirrors the production charset/length rule for assertions.
  private func isValidWireID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy {
      switch $0.value {
      case 48 ... 57, 65 ... 90, 97 ... 122, 45, 95: true
      default: false
      }
    }
  }

  // MARK: Tool Call ID Remapping in Messages

  @Test func remapsToolCallIdsAcrossMessages() {
    let compound = "call_abc|fc_def"
    var messages: [Message] = [
      .assistant(AssistantMessage(
        content: [.toolCall(ToolCall(
          id: compound,
          name: "search",
          arguments: .object([:]),
        ))],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: compound,
        content: [.text(TextContent(text: "result"))],
      )),
    ]

    normalizeToolCallIDs(in: &messages)

    // The pure mapping must rewrite the call and its result identically, with no
    // shared map — so they still pair up after normalization.
    let expected = wireToolCallID(compound)
    #expect(expected.hasPrefix("wuhu_"))

    if case let .assistant(msg) = messages[0],
       case let .toolCall(tc) = msg.content[0]
    {
      #expect(tc.id == expected)
    } else {
      Issue.record("Expected tool call")
    }

    if case let .toolResult(msg) = messages[1] {
      #expect(msg.toolCallId == expected)
    }
  }

  // MARK: Reasoning Normalization

  @Test func keepsSameProviderEncryptedReasoning() {
    var messages: [Message] = [
      .assistant(AssistantMessage(content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "anthropic", model: "claude",
          summary: "thinking", opaque: "sig_abc",
        ))),
      ])),
    ]

    normalizeReasoningForTarget(in: &messages, targetProviderID: "anthropic")

    // Same provider → opaque preserved (faithful replay, valid signature).
    if case let .assistant(msg) = messages[0],
       case let .reasoning(.encrypted(enc)) = msg.content[0]
    {
      #expect(enc.opaque == "sig_abc")
    } else {
      Issue.record("Expected encrypted reasoning preserved")
    }
  }

  @Test func convertsForeignEncryptedReasoningToText() {
    var messages: [Message] = [
      .assistant(AssistantMessage(content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "openai", model: "gpt-5.4",
          summary: "Searching the web", opaque: "gAAAAAB-fernet-token",
        ))),
        .text(TextContent(text: "answer")),
      ])),
    ]

    // Target is a different provider — the OpenAI opaque is unverifiable there.
    normalizeReasoningForTarget(in: &messages, targetProviderID: "anthropic")

    guard case let .assistant(msg) = messages[0] else { Issue.record("expected assistant"); return }
    #expect(msg.content.count == 2)
    if case let .text(t) = msg.content[0] {
      #expect(t.text == "Searching the web")
    } else {
      Issue.record("Expected reasoning summary converted to text")
    }
    if case let .text(t) = msg.content[1] {
      #expect(t.text == "answer")
    }
  }

  @Test func dropsForeignEncryptedReasoningWithoutSummary() {
    var messages: [Message] = [
      .assistant(AssistantMessage(content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "openai", model: "gpt-5.4",
          summary: nil, opaque: "gAAAAAB-opaque-only",
        ))),
        .text(TextContent(text: "answer")),
      ])),
    ]

    normalizeReasoningForTarget(in: &messages, targetProviderID: "anthropic")

    // No portable summary → the foreign block is dropped entirely.
    guard case let .assistant(msg) = messages[0] else { Issue.record("expected assistant"); return }
    #expect(msg.content.count == 1)
    if case let .text(t) = msg.content[0] {
      #expect(t.text == "answer")
    }
  }

  @Test func leavesUnencryptedReasoningUntouched() {
    var messages: [Message] = [
      .assistant(AssistantMessage(content: [
        .reasoning(.unencrypted("plain thoughts")),
      ])),
    ]

    normalizeReasoningForTarget(in: &messages, targetProviderID: "anthropic")

    if case let .assistant(msg) = messages[0],
       case .reasoning(.unencrypted) = msg.content[0]
    {
      // unchanged — plain text carries no signature
    } else {
      Issue.record("Expected unencrypted reasoning to be left as-is")
    }
  }

  @Test func gatesReasoningPerBlockInMixedOriginTranscript() {
    // The production scenario: GPT web-search turns and Anthropic turns in one
    // request to Anthropic. A conversation-level source provider can't express this.
    var messages: [Message] = [
      .assistant(AssistantMessage(content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "openai", model: "gpt-5.4",
          summary: "gpt thinking", opaque: "gAAAAAB-fernet",
        ))),
      ])),
      .assistant(AssistantMessage(content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "anthropic", model: "claude-opus-4-7",
          summary: "claude thinking", opaque: "anthropic_sig",
        ))),
      ])),
    ]

    normalizeReasoningForTarget(in: &messages, targetProviderID: "anthropic")

    // GPT block → converted to text; Anthropic block → kept with its signature.
    if case let .assistant(gpt) = messages[0], case .text = gpt.content[0] {
      // ok
    } else {
      Issue.record("GPT-origin reasoning should be converted to text")
    }
    if case let .assistant(claude) = messages[1],
       case let .reasoning(.encrypted(enc)) = claude.content[0]
    {
      #expect(enc.opaque == "anthropic_sig")
    } else {
      Issue.record("Anthropic-origin reasoning should be preserved")
    }
  }
}

extension CrossProviderNormalizationTests {
  @Test func hostedItemsStayOpaqueForTheirProviderAndDegradeElsewhere() throws {
    let payload = try #require(JSONValue.parse(#"{"id":"ws_1","type":"web_search_call","status":"completed","action":{"type":"search","queries":["swift"]}}"#))
    let item = try #require(HostedToolContent(providerID: "codex", payload: payload))
    let original: [Message] = [.assistant(.init(content: [.hostedTool(item)]))]

    var sameProvider = original
    normalizeHostedToolsForTarget(in: &sameProvider, targetProviderID: "codex")
    #expect(sameProvider == original)

    var foreignProvider = original
    normalizeHostedToolsForTarget(in: &foreignProvider, targetProviderID: "anthropic")
    #expect(foreignProvider == [.assistant(.init(content: [.text("web_search_call · search")]))])
  }
}
