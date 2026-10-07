import Foundation
import JSONValue
import Testing
@testable import WuhuAI

// MARK: - Responses Encoding Tests

@Suite struct ResponsesRequestBuilderTests {
  @Test func buildsBasicResponsesRequest() async throws {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Hello"))])),
      ],
    )

    let (url, headers, body) = try await buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    #expect(url.absoluteString == "https://api.openai.com/v1/responses")
    #expect(headers["content-type"] == "application/json")
    #expect(headers["accept"] == "text/event-stream")
    #expect(body["model"] == .string("gpt-5.4"))
    #expect(body["stream"] == .bool(true))
    #expect(body["store"] == .bool(false))

    let input = body["input"]?.array ?? []
    #expect(input.count == 2) // system + user

    let systemItem = input[0].object ?? [:]
    #expect(systemItem["role"] == .string("system"))
    #expect(systemItem["content"] == .string("You are helpful."))

    let userItem = input[1].object ?? [:]
    #expect(userItem["role"] == .string("user"))
  }

  @Test func buildsRequestWithReasoning() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(reasoning: .effort("high"))

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
      isCodex: false,
    )

    let reasoning = body["reasoning"]?.object ?? [:]
    #expect(reasoning["effort"] == .string("high"))
    #expect(reasoning["summary"] == .string("auto"))
    let include = body["include"]?.array ?? []
    #expect(include.contains(.string("reasoning.encrypted_content")))
  }

  @Test func buildsRequestWithTemperatureAndMaxTokens() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(temperature: 0.5, maxTokens: 200)

    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
      isCodex: false,
    )

    #expect(body["temperature"] == .number(0.5))
    #expect(body["max_output_tokens"] == .number(200))
  }

  @Test func codexRequestsOmitUnsupportedMaxOutputTokens() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(maxTokens: 200)

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: context,
      options: options,
      isCodex: true,
    )

    #expect(body["max_output_tokens"] == nil)
  }

  @Test func omitsVerbosityWhenUnspecified() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    #expect(body["text"] == nil)
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

    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let tools = body["tools"]?.array ?? []
    #expect(tools.count == 1)
    let tool = tools[0].object ?? [:]
    #expect(tool["type"] == .string("function"))
    #expect(tool["name"] == .string("search"))
  }

  @Test func buildsRequestWithAssistantHistory() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [.text(TextContent(text: "I can help"))],
      )),
      .user(UserMessage(content: [.text(TextContent(text: "Thanks"))])),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    // Find the message item
    let hasMessage = input.contains { item in
      item.object?["type"] == .string("message")
    }
    #expect(hasMessage)
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

    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    // Should have function_call and function_call_output
    let hasFunctionCall = input.contains { $0.object?["type"] == .string("function_call") }
    let hasOutput = input.contains { $0.object?["type"] == .string("function_call_output") }
    #expect(hasFunctionCall)
    #expect(hasOutput)
  }

  @Test func buildsRequestWithReasoningHistory() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai",
            model: "gpt-5.4",
            summary: "thinking summary",
            opaque: "encrypted_blob",
          ))),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    let hasReasoning = input.contains { $0.object?["type"] == .string("reasoning") }
    #expect(hasReasoning)
  }

  @Test func codexRequestsReplayableReasoningByDefault() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: context,
      options: RequestOptions(),
      isCodex: true,
    )

    let reasoning = body["reasoning"]?.object ?? [:]
    #expect(reasoning["effort"] == .string("medium"))
    #expect(reasoning["summary"] == .string("auto"))
    let include = body["include"]?.array ?? []
    #expect(include == [.string("reasoning.encrypted_content")])
  }

  @Test func skipsEmptyEncryptedReasoningHistory() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai-codex",
            model: "gpt-5.5",
            opaque: "",
            id: "rs_empty",
          ))),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: context,
      options: RequestOptions(),
      isCodex: true,
    )

    let input = body["input"]?.array ?? []
    let reasoningItems = input.filter { $0.object?["type"] == .string("reasoning") }
    #expect(reasoningItems.isEmpty)
  }

  @Test func dropsUnencryptedReasoningHistory() async throws {
    // Responses rejects `reasoning.content` on input and discards `summary`
    // before the model reads it, so clear reasoning has nowhere faithful to go.
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.unencrypted("plain reasoning")),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    #expect(!input.contains { $0.object?["type"] == .string("reasoning") })
    let messages = input.filter { $0.object?["type"] == .string("message") }
    #expect(messages.count == 1)
    let content = messages[0].object?["content"]?.array ?? []
    #expect(content.count == 1)
    #expect(content[0].object?["text"] == .string("answer"))
  }

  @Test func omitsFabricatedIdOnEncryptedReasoningWithoutOne() async throws {
    // An `rs_` id the server never issued is looked up and 404s the request.
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai",
            model: "gpt-5.5",
            opaque: "encrypted_blob",
          ))),
        ],
      )),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let item = try #require((body["input"]?.array ?? []).first?.object)
    #expect(item["type"] == .string("reasoning"))
    #expect(item["id"] == nil)
    #expect(item["encrypted_content"] == .string("encrypted_blob"))
  }

  @Test func preservesServerIssuedReasoningId() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai",
            model: "gpt-5.5",
            opaque: "encrypted_blob",
            id: "rs_real",
          ))),
        ],
      )),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let item = try #require((body["input"]?.array ?? []).first?.object)
    #expect(item["id"] == .string("rs_real"))
  }

  @Test func skipsSummaryOnlyEncryptedReasoningHistory() async throws {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai-codex",
            model: "gpt-5.5",
            summary: "reasoning summary",
            opaque: "",
            id: "rs_summary_only",
          ))),
        ],
      )),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.5",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: context,
      options: RequestOptions(),
      isCodex: true,
    )

    let input = body["input"]?.array ?? []
    #expect(input.isEmpty)
  }

  @Test func codexModePutsSystemPromptInInstructions() async throws {
    let context = Context(
      systemPrompt: "You are a coding assistant.",
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
    )

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.4-codex",
      baseURL: URL(string: "https://chatgpt.com/backend-api")!,
      context: context,
      options: RequestOptions(),
      isCodex: true,
    )

    #expect(body["instructions"] == .string("You are a coding assistant."))

    // In codex mode, system prompt should NOT be in input
    let input = body["input"]?.array ?? []
    let hasSystem = input.contains { $0.object?["role"] == .string("system") }
    #expect(!hasSystem)
  }

  @Test func nonCodexModeDoesNotPutInstructions() async throws {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
    )

    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    #expect(body["instructions"] == nil)
  }

  @Test func resolvesBlobImageURLsBeforeBuildingInputImageBlocks() async throws {
    let context = Context(messages: [
      .user(.init(content: [
        .text(.init(text: "What is this?")),
        .media(.init(
          url: URL(string: "wuhu://default.local/_/sessions/session-1/attachments/photo.png")!,
          mimeType: "image/png",
        )),
      ])),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
      mediaResolver: StaticMediaResolver(data: Data("png".utf8), mimeType: "image/png"),
    )

    let input = try #require(body["input"]?.array)
    let user = try #require(input.last?.object)
    let content = try #require(user["content"]?.array)
    let image = try #require(content.last?.object)
    #expect(image["type"] == .string("input_image"))
    #expect(image["image_url"] == .string("data:image/png;base64,cG5n"))
    #expect(image["detail"] == .string("original"), "auto would let OpenAI shrink what the resolver already fitted")
  }

  @Test func sendsAResolverLineAsInputText() async throws {
    let context = Context(messages: [
      .user(.init(content: [
        .media(.init(url: URL(string: "wuhu://default.local/big.png")!, mimeType: "image/png")),
      ])),
    ])
    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
      mediaResolver: LineMediaResolver(),
    )
    let user = try #require(body["input"]?.array?.last?.object)
    let part = try #require(user["content"]?.array?.first?.object)
    #expect(part["type"] == .string("input_text"))
    #expect(part["text"] == .string("[image not sent]"))
  }

  @Test func dropsMediaWhenResolverDoesNotOwnTheReference() async throws {
    // An unowned scheme with a resolver that returns nil must drop the media
    // block, not crash or emit an unresolvable reference.
    let context = Context(messages: [
      .user(.init(content: [
        .text(.init(text: "What is this?")),
        .media(.init(
          url: URL(string: "ipfs://some/unowned/reference.png")!,
          mimeType: "image/png",
        )),
      ])),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
      mediaResolver: NilMediaResolver(),
    )

    let input = try #require(body["input"]?.array)
    let user = try #require(input.last?.object)
    let content = try #require(user["content"]?.array)
    // Only the text part survives; the unresolvable media block is dropped.
    #expect(content.count == 1)
    #expect(content.allSatisfy { $0.object?["type"] != .string("input_image") })
  }

  @Test func preservesHTTPImageURLsWhenBuildingInputImageBlocks() async throws {
    let context = Context(messages: [
      .user(.init(content: [
        .media(.init(
          url: URL(string: "https://example.com/photo.png")!,
          mimeType: "image/png",
        )),
      ])),
    ])

    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = try #require(body["input"]?.array)
    let user = try #require(input.last?.object)
    let content = try #require(user["content"]?.array)
    let image = try #require(content.last?.object)
    #expect(image["image_url"] == .string("https://example.com/photo.png"))
  }
}

private struct StaticMediaResolver: MediaResolver {
  var data: Data
  var mimeType: String

  func resolve(_: MediaContent) async throws -> ResolvedMedia? {
    .data(data, mimeType: mimeType)
  }
}

private struct LineMediaResolver: MediaResolver {
  func resolve(_: MediaContent) async throws -> ResolvedMedia? {
    .text("[image not sent]")
  }
}

/// A resolver that owns nothing — every reference comes back as "not mine."
private struct NilMediaResolver: MediaResolver {
  func resolve(_: MediaContent) async throws -> ResolvedMedia? { nil }
}

extension ResponsesRequestBuilderTests {
  @Test func codexDoesNotInjectHostedWebSearch() async throws {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "search"))]))])
    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-5.6-sol",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: context,
      options: RequestOptions(),
      isCodex: true,
    )

    #expect(body["tools"] == nil)
  }

  @Test func codexDeclaresOnlyCallerTools() async throws {
    let tool = Tool(
      name: "run_script",
      description: "Run a script.",
      parameters: .object(["type": .string("object")]),
    )
    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-6.1-sol",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: Context(messages: [], tools: [tool]),
      options: RequestOptions(),
      isCodex: true,
    )

    #expect(body["tools"]?.array == [.object([
      "type": .string("function"),
      "name": .string("run_script"),
      "description": .string("Run a script."),
      "parameters": .object(["type": .string("object")]),
      "strict": .bool(false),
    ])])
  }

  @Test(arguments: [false, true])
  func explicitlyRequestedHostedToolsRemainSupported(isCodex: Bool) async throws {
    let (_, _, body) = try await buildResponsesRequest(
      model: "gpt-6.1-sol",
      baseURL: URL(string: "https://example.com")!,
      context: Context(messages: [], tools: [.hosted(type: "web_search")]),
      options: RequestOptions(),
      isCodex: isCodex,
    )

    #expect(body["tools"]?.array == [.object(["type": .string("web_search")])])
  }

  @Test func hostedItemsReplayDeterministically() async throws {
    let payload = try #require(JSONValue.parse(#"{ "id":"ws_1", "type":"web_search_call", "status":"completed", "action":{ "url":"https://example.com", "type":"open_page" } }"#))
    let item = try #require(HostedToolContent(providerID: "codex", payload: payload))
    let request = try await buildResponsesRequest(
      model: "gpt-5.6-sol",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: Context(messages: [.assistant(.init(content: [.hostedTool(item)]))]),
      options: RequestOptions(),
      isCodex: true,
    )

    let wire = JSONValue.object(request.body).jsonString()
    let replay = try await buildResponsesRequest(
      model: "gpt-5.6-sol",
      baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
      context: Context(messages: [.assistant(.init(content: [.hostedTool(item)]))]),
      options: RequestOptions(),
      isCodex: true,
    )
    #expect(wire == JSONValue.object(replay.body).jsonString())
    #expect(request.body["input"]?.array == [payload])
    #expect(request.body["tools"] == nil)
  }
}
