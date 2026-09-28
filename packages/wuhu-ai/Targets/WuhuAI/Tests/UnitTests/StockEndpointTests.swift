import Fetch
import JSONValue
import OrderedCollections
import Testing
@testable import WuhuAI

@Suite struct StockEndpointTests {
  @Test func codexEndpointOmitsOptionalOriginatorByDefault() {
    let endpoint = OpenAICodexEndpoint(
      model: "gpt-5.5",
      jwt: "token",
      chatgptAccountID: "account",
      sessionID: "conversation",
    )

    var headers = RequestHeaders()
    endpoint.modifyHeaders(&headers, options: RequestOptions())

    #expect(headers.sensitiveValues["authorization"] == "Bearer token")
    #expect(headers.sensitiveValues["chatgpt-account-id"] == "account")
    #expect(headers["session-id"] == "conversation")
    #expect(headers["originator"] == nil)
    #expect(headers["OpenAI-Beta"] == nil)
  }

  // Cache affinity rides on the headers; the body key is what pins the prefix
  // once a request has landed on a shard. One session id feeds all three, and
  // the `conversation_id` header we used to send is gone — nothing read it.
  @Test func codexEndpointCarriesTheSessionOnEveryCacheSurface() {
    let endpoint = OpenAICodexEndpoint(model: "gpt-5.5", jwt: "token", sessionID: "ses_42")
    var body: OrderedDictionary<String, JSONValue> = [:]
    var headers = RequestHeaders()

    endpoint.modifyBody(&body, options: RequestOptions())
    endpoint.modifyHeaders(&headers, options: RequestOptions())

    #expect(body["prompt_cache_key"] == .string("ses_42"))
    #expect(headers["session-id"] == "ses_42")
    #expect(headers["thread-id"] == "ses_42")
    #expect(headers["conversation_id"] == nil)
  }

  @Test func codexEndpointOmitsCacheSurfacesWithoutASession() {
    let endpoint = OpenAICodexEndpoint(model: "gpt-5.5", jwt: "token")
    var body: OrderedDictionary<String, JSONValue> = [:]
    var headers = RequestHeaders()

    endpoint.modifyBody(&body, options: RequestOptions())
    endpoint.modifyHeaders(&headers, options: RequestOptions())

    #expect(body["prompt_cache_key"] == nil)
    #expect(headers["session-id"] == nil)
    #expect(headers["thread-id"] == nil)
  }

  @Test func codexEndpointDefaultsToMediumVerbosity() {
    let endpoint = OpenAICodexEndpoint(model: "gpt-5.5", jwt: "token")
    var body: OrderedDictionary<String, JSONValue> = [:]

    endpoint.modifyBody(&body, options: RequestOptions())

    let text = body["text"]?.object ?? [:]
    #expect(text["verbosity"] == .string("medium"))
  }

  @Test func codexEndpointUsesExplicitVerbosity() {
    let endpoint = OpenAICodexEndpoint(model: "gpt-5.5", jwt: "token", verbosity: .low)
    var body: OrderedDictionary<String, JSONValue> = [:]

    endpoint.modifyBody(&body, options: RequestOptions())

    let text = body["text"]?.object ?? [:]
    #expect(text["verbosity"] == .string("low"))
  }

  @Test func codexEndpointPreservesExistingTextOptions() {
    let endpoint = OpenAICodexEndpoint(model: "gpt-5.5", jwt: "token", verbosity: .low)
    var body: OrderedDictionary<String, JSONValue> = [
      "text": .object(["format": .string("text")]),
    ]

    endpoint.modifyBody(&body, options: RequestOptions())

    let text = body["text"]?.object ?? [:]
    #expect(text["verbosity"] == .string("low"))
    #expect(text["format"] == .string("text"))
  }

  @Test func gptEndpointUsesExplicitVerbosity() {
    let endpoint = OpenAIGPTEndpoint(model: "gpt-5.5", apiKey: "token", verbosity: .low)
    var body: OrderedDictionary<String, JSONValue> = [:]

    endpoint.modifyBody(&body, options: RequestOptions())

    let text = body["text"]?.object ?? [:]
    #expect(text["verbosity"] == .string("low"))
  }

  @Test func stockEndpointsMarkCredentialHeadersSensitiveAtCreationSite() {
    // Each provider configures its own headers; capture the sensitive keys it
    // marks at the creation site.
    func sensitiveKeys(_ modify: (inout RequestHeaders) -> Void) -> Set<String> {
      var headers = RequestHeaders()
      modify(&headers)
      return Set(headers.sensitiveValues.keys)
    }
    let opts = RequestOptions()

    #expect(sensitiveKeys { OpenAIGPTEndpoint(model: "gpt", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["authorization"])
    #expect(sensitiveKeys { OpenAICodexEndpoint(model: "codex", jwt: "token", chatgptAccountID: "account").modifyHeaders(&$0, options: opts) } == ["authorization", "chatgpt-account-id"])
    #expect(sensitiveKeys { AnthropicEndpoint(model: "claude", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["x-api-key"])
    #expect(sensitiveKeys { DeepSeekChatEndpoint(model: "deepseek-chat", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["authorization"])
    #expect(sensitiveKeys { DeepSeekAnthropicEndpoint(model: "deepseek", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["authorization"])
    #expect(sensitiveKeys { GeminiEndpoint(model: "gemini", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["x-goog-api-key"])
    #expect(sensitiveKeys { KimiEndpoint(model: "kimi", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["authorization"])
    #expect(sensitiveKeys { QwenEndpoint(model: "qwen", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["authorization"])
    #expect(sensitiveKeys { GLMEndpoint(model: "glm-5.2", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["authorization"])
    #expect(sensitiveKeys { MiniMaxEndpoint(model: "minimax", apiKey: "token").modifyHeaders(&$0, options: opts) } == ["x-api-key"])
  }

  @Test func nonCredentialCodexHeadersAreNotSensitive() {
    let endpoint = OpenAICodexEndpoint(
      model: "gpt-5.5",
      jwt: "token",
      chatgptAccountID: "account",
      sessionID: "conversation",
      originator: "wuhu",
    )
    var headers = RequestHeaders()
    endpoint.modifyHeaders(&headers, options: RequestOptions())

    #expect(headers.sensitiveValues["authorization"] == "Bearer token")
    #expect(headers.sensitiveValues["chatgpt-account-id"] == "account")
    #expect(headers.values["session-id"] == "conversation")
    #expect(headers.values["thread-id"] == "conversation")
    #expect(headers.values["originator"] == "wuhu")
  }
}

// Under thinking, DeepSeek rejects any tool_use turn that carries no thinking
// block. Verified live against api.deepseek.com/anthropic on 2026-08-19: the
// block's text is never read back, so an empty one satisfies the check while a
// missing one 400s.
@Suite struct DeepSeekPlaceholderThinkingTests {
  private func toolCall(_ id: String, thinking: Bool) -> Message {
    var content: [ContentBlock] = []
    if thinking { content.append(.reasoning(.unencrypted("weighing it"))) }
    content.append(.toolCall(ToolCall(id: id, name: "await_reply", arguments: .object([:]))))
    return .assistant(AssistantMessage(content: content))
  }

  private func toolResult(_ id: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, content: [.text("ok")]))
  }

  private func user(_ text: String) -> Message {
    .user(UserMessage(content: [.text(TextContent(text: text))]))
  }

  private func body(
    _ messages: [Message],
    options: RequestOptions = RequestOptions(reasoning: .effort("high")),
  ) async throws -> OrderedDictionary<String, JSONValue> {
    let endpoint = DeepSeekAnthropicEndpoint(model: "deepseek-v4-flash", apiKey: "k")
    let waitTool = Tool(
      name: "await_reply",
      description: "Wait for the opponent.",
      parameters: .object(["type": .string("object"), "properties": .object([:])]),
    )
    var (_, _, body) = try await buildAnthropicRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: Context(messages: messages, tools: [waitTool]),
      options: options,
    )
    endpoint.modifyBody(&body, options: options)
    return body
  }

  private func toolTurns(_ body: OrderedDictionary<String, JSONValue>) -> [[JSONValue]] {
    (body["messages"]?.array ?? []).compactMap { message in
      guard message.object?["role"]?.stringValue == "assistant",
            let content = message.object?["content"]?.array,
            content.contains(where: { $0.object?["type"]?.stringValue == "tool_use" })
      else { return nil }
      return content
    }
  }

  private func thinkingTexts(_ body: OrderedDictionary<String, JSONValue>) -> [String?] {
    toolTurns(body).map { content in
      content.first { $0.object?["type"]?.stringValue == "thinking" }?
        .object?["thinking"]?.stringValue
    }
  }

  @Test func fabricatedAnchorGetsAPlaceholderInsteadOfCostingThinking() async throws {
    let body = try await body([
      toolCall("anchor", thinking: false),
      toolResult("anchor"),
      user("your move"),
    ])
    #expect(body["thinking"] == .object(["type": .string("enabled")]))
    #expect(body["output_config"] == .object(["effort": .string("high")]))
    #expect(thinkingTexts(body) == [""])
  }

  @Test func everyThinklessToolTurnGetsAPlaceholder() async throws {
    let body = try await body([
      user("your move"),
      toolCall("c1", thinking: false),
      toolResult("c1"),
      toolCall("c2", thinking: true),
      toolResult("c2"),
    ])
    #expect(body["thinking"] == .object(["type": .string("enabled")]))
    #expect(thinkingTexts(body) == ["", "weighing it"])
  }

  @Test func placeholderLeadsTheContentBlocks() async throws {
    let body = try await body([user("your move"), toolCall("c1", thinking: false), toolResult("c1")])
    let content = try #require(toolTurns(body).first)
    #expect(content.map { $0.object?["type"]?.stringValue } == ["thinking", "tool_use"])
  }

  @Test func aThinkingOffRequestIsLeftAlone() async throws {
    let body = try await body(
      [user("your move"), toolCall("c1", thinking: false), toolResult("c1")],
      options: RequestOptions(reasoning: .effort("high"), toolChoice: .tool(name: "await_reply")),
    )
    #expect(body["thinking"] == .object(["type": .string("disabled")]))
    #expect(thinkingTexts(body) == [nil])
  }
}

private actor ResponseHeaderRecorder {
  var headers: [String: String] = [:]

  func record(_ headers: [String: String]) {
    self.headers = headers
  }
}

@Test func codexEndpointReportsHeadersFromErrorResponses() async throws {
  let recorder = ResponseHeaderRecorder()
  let endpoint = OpenAICodexEndpoint(
    model: "gpt-5.5",
    jwt: "token",
    receiveResponseHeaders: { await recorder.record($0) },
  ).withFetch(FetchClient { _ in
    Response(
      status: .init(code: 429),
      headers: RequestHeaders(values: [
        "X-Codex-Plan-Type": "pro",
        "X-Codex-Primary-Used-Percent": "12.5",
      ]).fields,
      body: .string("rate limited"),
    )
  })

  do {
    _ = try await endpoint.inference(context: Context(messages: [])).collect()
    Issue.record("expected rate limit failure")
  } catch {}

  #expect(await recorder.headers == [
    "x-codex-plan-type": "pro",
    "x-codex-primary-used-percent": "12.5",
  ])
}
