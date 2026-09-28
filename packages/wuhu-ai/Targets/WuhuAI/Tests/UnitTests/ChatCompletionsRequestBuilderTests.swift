import Foundation
import Testing
@testable import WuhuAI

// MARK: - Chat Completions Encoding Tests

@Suite struct ChatCompletionsRequestBuilderTests {
  @Test func buildsBasicChatCompletionsRequest() async throws {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Hello"))])),
      ],
    )

    let (url, headers, body) = try await buildChatCompletionsRequest(
      model: "test-model",
      baseURL: URL(string: "https://api.example.com/v1")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: nil,
    )

    #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    #expect(headers["content-type"] == "application/json")
    #expect(headers["accept"] == "text/event-stream")
    #expect(body["model"] == .string("test-model"))
    #expect(body["stream"] == .bool(true))

    let messages = body["messages"]?.array ?? []
    #expect(messages.count == 2) // system + user

    let systemMsg = messages[0].object ?? [:]
    #expect(systemMsg["role"] == .string("system"))
    #expect(systemMsg["content"] == .string("You are helpful."))

    let userMsg = messages[1].object ?? [:]
    #expect(userMsg["role"] == .string("user"))
    // Single text block → content is a plain string
    #expect(userMsg["content"] == .string("Hello"))
  }

  @Test func buildsRequestWithTemperatureAndMaxTokens() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(temperature: 0.7, maxTokens: 100)

    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
      mediaResolver: nil,
    )

    #expect(body["temperature"] == .number(0.7))
    #expect(body["max_tokens"] == .number(100))
  }

  @Test func buildsRequestWithTools() async throws {
    let context = Context(
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
      tools: [Tool(
        name: "search",
        description: "Search the web",
        parameters: .object(["type": .string("object")]),
      )],
    )

    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: nil,
    )

    let tools = body["tools"]?.array ?? []
    #expect(tools.count == 1)
    let tool = tools[0].object ?? [:]
    #expect(tool["type"] == .string("function"))
    let function = tool["function"]?.object ?? [:]
    #expect(function["name"] == .string("search"))
    #expect(function["description"] == .string("Search the web"))
  }

  @Test func buildsRequestWithAssistantMessage() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [.text(TextContent(text: "I can help"))],
      )),
      .user(UserMessage(content: [.text(TextContent(text: "Thanks"))])),
    ])

    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: nil,
    )

    let messages = body["messages"]?.array ?? []
    let assistantMsg = messages[0].object ?? [:]
    #expect(assistantMsg["role"] == .string("assistant"))
  }

  @Test func buildsRequestWithToolCalls() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .toolCall(ToolCall(
            id: "call_1",
            name: "search",
            arguments: .object(["query": .string("test")]),
          )),
        ],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: "call_1",
        content: [.text(TextContent(text: "result"))],
      )),
    ])

    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: nil,
    )

    let messages = body["messages"]?.array ?? []
    let assistantMsg = messages[0].object ?? [:]
    let toolCalls = assistantMsg["tool_calls"]?.array ?? []
    #expect(toolCalls.count == 1)

    let toolResultMsg = messages[1].object ?? [:]
    #expect(toolResultMsg["role"] == .string("tool"))
    #expect(toolResultMsg["tool_call_id"] == .string("call_1"))
  }

  /// A resolved `text/*` attachment must be inlined as a plain TEXT content part,
  /// never an `image_url` part. Image-only providers (DeepSeek) reject a non-image
  /// `image_url`, which silently dropped channel/text attachments from the prompt
  /// (the `unknown variant 'application/octet-stream'` 400). Regression guard.
  @Test func inlinesTextAttachmentAsTextNotImage() async throws {
    let resolver = StubMediaResolver(data: Data("secret keyword: PINEAPPLE".utf8), mimeType: "text/plain")
    let context = Context(messages: [
      .user(UserMessage(content: [
        .text(TextContent(text: "Read the attachment.")),
        .media(MediaContent(url: URL(string: "channels://ch_abcd1234/attachments/2026/01/01/notes.txt")!, mimeType: "text/plain")),
      ])),
    ])

    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "deepseek-v4-pro",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      mediaResolver: resolver,
    )

    let messages = body["messages"]?.array ?? []
    let parts = messages[0].object?["content"]?.array ?? []
    // No `image_url` part for a text attachment.
    #expect(!parts.contains { $0.object?["type"] == .string("image_url") })
    // The attachment's decoded text is present as a text part, framed by filename.
    let textParts = parts.compactMap { $0.object?["text"]?.stringValue }
    #expect(textParts.contains { $0.contains("PINEAPPLE") && $0.contains("notes.txt") })
  }
}

/// A resolver that returns fixed bytes for any media URL — exercises the
/// resolved-`.data` branch of the dialect's media handling.
private struct StubMediaResolver: MediaResolver {
  let data: Data
  let mimeType: String
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    .data(data, mimeType: mimeType)
  }
}
