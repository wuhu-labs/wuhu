import Foundation
import JSONValue
import OrderedCollections
import Testing
@testable import WuhuAI

// MARK: - Anthropic Encoding Tests

@Suite struct AnthropicRequestBuilderTests {
  @Test(arguments: [
    ("https://api.anthropic.com", "https://api.anthropic.com/v1/messages"),
    ("https://api.anthropic.com/", "https://api.anthropic.com/v1/messages"),
    ("https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages"),
    ("https://api.anthropic.com/v1/", "https://api.anthropic.com/v1/messages"),
    ("https://api.deepseek.com/anthropic", "https://api.deepseek.com/anthropic/v1/messages"),
    ("https://api.xiaomimimo.com/anthropic", "https://api.xiaomimimo.com/anthropic/v1/messages"),
    ("https://api.xiaomimimo.com/anthropic/", "https://api.xiaomimimo.com/anthropic/v1/messages"),
    ("https://api.xiaomimimo.com/anthropic/v1", "https://api.xiaomimimo.com/anthropic/v1/messages"),
    ("http://localhost:8080/proxy/v1v", "http://localhost:8080/proxy/v1v/v1/messages"),
  ])
  func messagesURLFollowsTheSDKConvention(baseURL: String, expected: String) {
    #expect(anthropicMessagesURL(baseURL: URL(string: baseURL)!).absoluteString == expected)
  }

  @Test func buildsBasicAnthropicRequest() async throws {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Hello"))])),
      ],
    )

    let (url, headers, body) = try await buildAnthropicRequest(
      model: "claude-sonnet-4-6",
      baseURL: URL(string: "https://api.anthropic.com")!,
      context: context,
      options: RequestOptions(),
    )

    #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(headers["content-type"] == "application/json")
    #expect(headers["accept"] == "text/event-stream")
    #expect(headers["anthropic-version"] == "2023-06-01")
    #expect(body["model"] == .string("claude-sonnet-4-6"))
    #expect(body["stream"] == .bool(true))
    #expect(body["max_tokens"] == .number(16384))

    #expect(body["system"] == .string("You are helpful."))

    let messages = body["messages"]?.array ?? []
    #expect(messages.count == 1)
    let userMsg = messages[0].object ?? [:]
    #expect(userMsg["role"] == .string("user"))
  }

  @Test func buildsRequestWithTemperature() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(temperature: 0.7)

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
    )

    #expect(body["temperature"] == .number(0.7))
  }

  @Test func buildsRequestWithMaxTokens() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(maxTokens: 500)

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
    )

    #expect(body["max_tokens"] == .number(500))
  }

  @Test func anthropicPromptCacheDisabledOmitsCacheControl() async throws {
    var body: OrderedDictionary<String, JSONValue> = [:]
    let endpoint = AnthropicEndpoint(model: "m", apiKey: "key", promptCache: .disabled)

    endpoint.modifyBody(&body, options: RequestOptions())

    #expect(body["cache_control"] == nil)
  }

  @Test func anthropicPromptCacheFiveMinutesUsesEphemeralCacheControl() async throws {
    var body: OrderedDictionary<String, JSONValue> = [:]
    let endpoint = AnthropicEndpoint(model: "m", apiKey: "key", promptCache: .fiveMinutes)

    endpoint.modifyBody(&body, options: RequestOptions())

    #expect(body["cache_control"] == .object(["type": .string("ephemeral")]))
  }

  @Test func anthropicPromptCacheOneHourUsesTTL() async throws {
    var body: OrderedDictionary<String, JSONValue> = [:]
    let endpoint = AnthropicEndpoint(model: "m", apiKey: "key", promptCache: .oneHour)

    endpoint.modifyBody(&body, options: RequestOptions())

    #expect(body["cache_control"] == .object([
      "type": .string("ephemeral"),
      "ttl": .string("1h"),
    ]))
  }

  @Test func buildsRequestWithTools() async throws {
    let context = Context(
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
      tools: [Tool(
        name: "search",
        description: "Search",
        parameters: .object(["type": .string("object")]),
      )],
    )

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let tools = body["tools"]?.array ?? []
    #expect(tools.count == 1)
    let tool = tools[0].object ?? [:]
    #expect(tool["name"] == .string("search"))
    #expect(tool["input_schema"] != nil)
  }

  @Test func buildsRequestWithAssistantBlocks() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: "Let me think...",
            opaque: "sig_abc",
          ))),
          .text(TextContent(text: "Here is the answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let assistantMsg = messages[0].object ?? [:]
    #expect(assistantMsg["role"] == .string("assistant"))

    let content = assistantMsg["content"]?.array ?? []
    #expect(content.count == 2) // thinking + text

    let thinkingBlock = content[0].object ?? [:]
    #expect(thinkingBlock["type"] == .string("thinking"))
    #expect(thinkingBlock["thinking"] == .string("Let me think..."))
    #expect(thinkingBlock["signature"] == .string("sig_abc"))

    let textBlock = content[1].object ?? [:]
    #expect(textBlock["type"] == .string("text"))
    #expect(textBlock["text"] == .string("Here is the answer"))
  }

  @Test func unencryptedReasoningBecomesUnsignedThinkingWhenAccepted() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.unencrypted("cross-provider thoughts")),
          .text(TextContent(text: "the answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      acceptsUnsignedThinking: true,
    )

    let content = body["messages"]?.array?[0].object?["content"]?.array ?? []
    #expect(content.count == 2)
    let first = content[0].object ?? [:]
    #expect(first["type"] == .string("thinking"))
    #expect(first["thinking"] == .string("cross-provider thoughts"))
    #expect(first["signature"] == nil)
    #expect(first["text"] == nil)
  }

  @Test func unencryptedReasoningDegradesToTextWhenUnsignedThinkingRejected() async throws {
    // api.anthropic.com answers an unsigned thinking block with
    // "thinking.signature: Field required".
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.unencrypted("cross-provider thoughts")),
          .text(TextContent(text: "the answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      acceptsUnsignedThinking: false,
    )

    let content = body["messages"]?.array?[0].object?["content"]?.array ?? []
    #expect(content.count == 2)
    let first = content[0].object ?? [:]
    #expect(first["type"] == .string("text"))
    #expect(first["text"] == .string("cross-provider thoughts"))
    #expect(first["thinking"] == nil)
    #expect(first["signature"] == nil)
  }

  @Test func buildsRequestWithRedactedThinking() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: nil,
            opaque: "redacted_data",
            redacted: true,
          ))),
        ],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let content = messages[0].object?["content"]?.array ?? []
    let block = content[0].object ?? [:]
    #expect(block["type"] == .string("redacted_thinking"))
    #expect(block["data"] == .string("redacted_data"))
  }

  @Test func buildsRequestWithToolCalls() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .toolCall(ToolCall(
            id: "toolu_001",
            name: "search",
            arguments: .object(["query": .string("test")]),
          )),
        ],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let content = messages[0].object?["content"]?.array ?? []
    let block = content[0].object ?? [:]
    #expect(block["type"] == .string("tool_use"))
    #expect(block["id"] == .string("toolu_001"))
    #expect(block["name"] == .string("search"))
  }

  @Test func groupsConsecutiveToolResults() async throws {
    let context = Context(messages: [
      .toolResult(ToolResultMessage(
        toolCallId: "toolu_001",
        content: [.text(TextContent(text: "result1"))],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: "toolu_002",
        content: [.text(TextContent(text: "result2"))],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    #expect(messages.count == 1) // grouped into one user message
    let content = messages[0].object?["content"]?.array ?? []
    #expect(content.count == 2) // two tool_results
  }

  @Test func parallelToolCallPairsEveryToolUseDespiteInterleavedEffect() async throws {
    // A parallel tool-call turn issues two tool_use blocks. In the transcript a
    // rendered `.effect` lands as a `.user` message BETWEEN the two sibling tool
    // results (the AgentLoop reducer appends `toolResult(A)` → effect → `toolResult(B)`).
    // The immediately-following provider message must still pair BOTH tool_use ids
    // with their tool_result, or DeepSeek's Anthropic endpoint rejects the turn with
    // "tool_use ids were found without tool_result blocks immediately after".
    let context = Context(messages: [
      .assistant(AssistantMessage(content: [
        .toolCall(ToolCall(id: "call_A", name: "mount", arguments: .object([:]))),
        .toolCall(ToolCall(id: "call_B", name: "find", arguments: .object([:]))),
      ])),
      .toolResult(ToolResultMessage(toolCallId: "call_A", content: [.text(TextContent(text: "mounted"))])),
      // Interleaved effect, rendered as a user message between sibling results.
      .user(UserMessage(content: [.text(TextContent(text: "<effect type=mount>...</effect>"))])),
      .toolResult(ToolResultMessage(toolCallId: "call_B", content: [.text(TextContent(text: "found"))])),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "deepseek-chat",
      baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    // Collect every tool_use id from assistant messages, and every tool_result
    // id from the user message that immediately follows each assistant message.
    var orphaned: [String] = []
    for (index, message) in messages.enumerated() {
      let obj = message.object ?? [:]
      guard obj["role"] == .string("assistant") else { continue }
      let toolUseIDs = (obj["content"]?.array ?? []).compactMap { block -> String? in
        let b = block.object ?? [:]
        guard b["type"] == .string("tool_use") else { return nil }
        if case let .string(id)? = b["id"] { return id }
        return nil
      }
      guard !toolUseIDs.isEmpty else { continue }

      // The next message must be a user message answering all of these ids.
      let next = index + 1 < messages.count ? (messages[index + 1].object ?? [:]) : [:]
      let resultIDs: Set<String> = next["role"] == .string("user")
        ? Set((next["content"]?.array ?? []).compactMap { block -> String? in
          let b = block.object ?? [:]
          guard b["type"] == .string("tool_result") else { return nil }
          if case let .string(id)? = b["tool_use_id"] { return id }
          return nil
        })
        : []
      for id in toolUseIDs where !resultIDs.contains(id) { orphaned.append(id) }
    }

    #expect(orphaned.isEmpty, "tool_use ids without an immediately-following tool_result: \(orphaned)")

    // The interleaved effect must survive — emitted AFTER the paired results.
    let userTexts = messages.compactMap { m -> String? in
      let obj = m.object ?? [:]
      guard obj["role"] == .string("user") else { return nil }
      return (obj["content"]?.array ?? []).compactMap { block -> String? in
        let b = block.object ?? [:]
        if b["type"] == .string("text"), case let .string(t)? = b["text"] { return t }
        return nil
      }.first
    }
    #expect(userTexts.contains("<effect type=mount>...</effect>"))
  }

  @Test func skipsVacuousReasoningBlock() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: "",
            opaque: "",
          ))),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let content = messages[0].object?["content"]?.array ?? []
    // Vacuous block should be skipped, leaving only the text block
    #expect(content.count == 1)
    #expect(content[0].object?["type"] == .string("text"))
  }

  @Test func redactedFlagDisambiguatesRedactedFromNoSummaryThinking() async throws {
    // summary:nil + redacted:false + non-empty opaque → thinking block (not redacted_thinking)
    let notRedacted = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: nil,
            opaque: "sig_abc",
            redacted: false,
          ))),
        ],
      )),
    ])

    let (_, _, body1) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: notRedacted,
      options: RequestOptions(),
    )

    let block1 = (body1["messages"]?.array ?? [])[0]
      .object?["content"]?.array?[0].object ?? [:]
    #expect(block1["type"] == .string("thinking"))
    #expect(block1["signature"] == .string("sig_abc"))

    // summary:nil + redacted:true + non-empty opaque → redacted_thinking block
    let redacted = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: nil,
            opaque: "redacted_blob",
            redacted: true,
          ))),
        ],
      )),
    ])

    let (_, _, body2) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: redacted,
      options: RequestOptions(),
    )

    let block2 = (body2["messages"]?.array ?? [])[0]
      .object?["content"]?.array?[0].object ?? [:]
    #expect(block2["type"] == .string("redacted_thinking"))
    #expect(block2["data"] == .string("redacted_blob"))
  }

  /// A resolved `text/*` attachment must inline as a TEXT block, never an `image`
  /// block. The DeepSeek Anthropic-compatible endpoint gates `source.media_type`
  /// on image types and rejects a non-image media block, which silently dropped
  /// channel/text attachments from the prompt (the `expected one of image/jpeg…`
  /// 400). Regression guard.
  @Test func inlinesTextAttachmentAsTextNotImage() async throws {
    let resolver = AnthropicStubMediaResolver(data: Data("secret keyword: PINEAPPLE".utf8), mimeType: "text/plain")
    let context = Context(messages: [
      .user(UserMessage(content: [
        .text(TextContent(text: "Read the attachment.")),
        .media(MediaContent(url: URL(string: "channels://ch_abcd1234/attachments/2026/01/01/notes.txt")!, mimeType: "text/plain")),
      ])),
    ])

    let (_, _, body) = try await buildAnthropicRequest(
      model: "deepseek-v4-pro",
      baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: resolver,
    )

    let parts = (body["messages"]?.array ?? [])[0].object?["content"]?.array ?? []
    // No `image` block for a text attachment.
    #expect(!parts.contains { $0.object?["type"] == .string("image") })
    // The attachment's decoded text is present as a text block, framed by name.
    let textBlocks = parts.compactMap { $0.object?["text"]?.stringValue }
    #expect(textBlocks.contains { $0.contains("PINEAPPLE") && $0.contains("notes.txt") })
  }
}

extension AnthropicRequestBuilderTests {
  @Test func sendsAResolverLineAsAText() async throws {
    let context = Context(messages: [
      .user(UserMessage(content: [
        .media(MediaContent(url: URL(string: "wuhu://default.local/big.png")!, mimeType: "image/png")),
      ])),
    ])
    let (_, _, body) = try await buildAnthropicRequest(
      model: "claude-opus-4-7",
      baseURL: URL(string: "https://api.anthropic.com/v1")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: AnthropicLineMediaResolver(),
    )
    let part = (body["messages"]?.array ?? [])[0].object?["content"]?.array?.first?.object ?? [:]
    #expect(part["type"] == .string("text"))
    #expect(part["text"] == .string("[image not sent]"))
  }
}

private struct AnthropicLineMediaResolver: MediaResolver {
  func resolve(_: MediaContent) async throws -> ResolvedMedia? {
    .text("[image not sent]")
  }
}

/// A resolver that returns fixed bytes for any media URL — exercises the
/// resolved-`.data` branch of the Anthropic dialect's media handling.
private struct AnthropicStubMediaResolver: MediaResolver {
  let data: Data
  let mimeType: String
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    .data(data, mimeType: mimeType)
  }
}
