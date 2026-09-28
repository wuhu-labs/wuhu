import Foundation
import Testing
@testable import WuhuAI

// MARK: - Gemini Encoding Tests

@Suite struct GeminiRequestBuilderTests {
  @Test func buildsBasicGeminiRequest() async throws {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Hello"))])),
      ],
    )

    let (url, headers, body) = try await buildGeminiRequest(
      model: "gemini-2.5-flash",
      baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    #expect(url.absoluteString.contains("gemini-2.5-flash:streamGenerateContent"))
    #expect(url.absoluteString.contains("alt=sse"))
    #expect(headers["content-type"] == "application/json")

    // System instruction
    let systemInstruction = body["systemInstruction"]?.object ?? [:]
    let systemParts = systemInstruction["parts"]?.array ?? []
    #expect(systemParts.first?.object?["text"] == .string("You are helpful."))

    // Contents
    let contents = body["contents"]?.array ?? []
    #expect(contents.count == 1)
    let userContent = contents[0].object ?? [:]
    #expect(userContent["role"] == .string("user"))
    let parts = userContent["parts"]?.array ?? []
    #expect(parts.first?.object?["text"] == .string("Hello"))
  }

  @Test func buildsRequestWithTemperatureAndMaxTokens() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(temperature: 0.5, maxTokens: 200)

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: options,
    )

    let config = body["generationConfig"]?.object ?? [:]
    #expect(config["temperature"] == .number(0.5))
    #expect(config["maxOutputTokens"] == .number(200))
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

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    let tools = body["tools"]?.array ?? []
    let toolObj = tools.first?.object ?? [:]
    let declarations = toolObj["functionDeclarations"]?.array ?? []
    #expect(declarations.count == 1)
    #expect(declarations.first?.object?["name"] == .string("search"))
  }

  @Test func buildsRequestWithAssistantHistory() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [.text(TextContent(text: "I can help"))],
      )),
      .user(UserMessage(content: [.text(TextContent(text: "Thanks"))])),
    ])

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    let contents = body["contents"]?.array ?? []
    let assistantContent = contents[0].object ?? [:]
    #expect(assistantContent["role"] == .string("model"))
  }

  @Test func buildsRequestWithToolCalls() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .toolCall(ToolCall(
            id: "uuid",
            name: "search",
            arguments: .object(["query": .string("test")]),
          )),
        ],
      )),
    ])

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    let contents = body["contents"]?.array ?? []
    let parts = contents[0].object?["parts"]?.array ?? []
    let funcPart = parts.first?.object?["functionCall"]?.object ?? [:]
    #expect(funcPart["name"] == .string("search"))
  }

  @Test func buildsRequestWithToolResults() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(content: [
        .toolCall(ToolCall(id: "uuid", name: "search", arguments: .object([:]))),
      ])),
      .toolResult(ToolResultMessage(
        toolCallId: "uuid",
        content: [.text(TextContent(text: #"{"result": "found"}"#))],
      )),
    ])

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    let contents = body["contents"]?.array ?? []
    // Should have assistant then tool result user message
    #expect(contents.count == 2)

    let toolResultParts = contents[1].object?["parts"]?.array ?? []
    let funcResponse = toolResultParts.first?.object?["functionResponse"]?.object ?? [:]
    #expect(funcResponse["name"] == .string("search"))
  }

  @Test func fusesThoughtSignatureWithFollowingTextBlock() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "gemini",
            model: "gemini",
            summary: nil,
            opaque: "thought_sig_123",
          ))),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    let contents = body["contents"]?.array ?? []
    let assistantContent = contents[0].object ?? [:]
    let parts = assistantContent["parts"]?.array ?? []
    // Only one part — the thinking should be fused into the text part
    #expect(parts.count == 1)
    let textPart = parts[0].object ?? [:]
    #expect(textPart["text"] == .string("answer"))
    #expect(textPart["thoughtSignature"] == .string("thought_sig_123"))
  }

  @Test func fusesThoughtSignatureWithFollowingToolCall() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "gemini",
            model: "gemini",
            summary: nil,
            opaque: "thought_sig",
          ))),
          .toolCall(ToolCall(
            id: "uuid",
            name: "search",
            arguments: .object([:]),
          )),
        ],
      )),
    ])

    let (_, _, body) = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1beta")!,
      context: context,
      options: RequestOptions(),
    )

    let contents = body["contents"]?.array ?? []
    let parts = contents[0].object?["parts"]?.array ?? []
    #expect(parts.count == 1)
    let funcPart = parts[0].object ?? [:]
    #expect(funcPart["thoughtSignature"] == .string("thought_sig"))
  }
}
