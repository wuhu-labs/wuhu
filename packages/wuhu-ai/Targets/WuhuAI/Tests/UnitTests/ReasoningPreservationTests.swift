import Fetch
import Foundation
import JSONValue
import OrderedCollections
import Testing
@testable import WuhuAI

// The wire facts these tests pin were probed against live providers on
// 2026-07-29; each one is a 400 or a silently dropped reasoning trace if it
// regresses.

@Suite struct ReasoningPreservationTests {
  // MARK: - Fixtures

  private var historyWithReasoning: Context {
    Context(
      systemPrompt: "You are 貂蝉.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "第一轮"))])),
        .assistant(AssistantMessage(content: [
          .reasoning(.unencrypted("王允在试探我。")),
          .text(TextContent(text: "妾身明白。")),
        ])),
        .user(UserMessage(content: [.text(TextContent(text: "第二轮"))])),
      ],
    )
  }

  private func emittedBody(
    _ endpoint: some ChatCompletionsEndpoint,
    _ context: Context,
    _ options: RequestOptions = RequestOptions(),
  ) async throws -> OrderedDictionary<String, JSONValue> {
    var (_, _, body) = try await buildChatCompletionsRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: normalizedRequestContext(context, targetProviderID: endpoint.providerID),
      options: options,
      mediaResolver: nil,
    )
    endpoint.modifyBody(&body, options: options)
    return body
  }

  private func assistantMessages(
    _ body: OrderedDictionary<String, JSONValue>,
  ) -> [OrderedDictionary<String, JSONValue>] {
    (body["messages"]?.array ?? [])
      .compactMap(\.object)
      .filter { $0["role"] == .string("assistant") }
  }

  // MARK: - GLM

  @Test func glmDefaultsToZhipuBaseAndBearerAuth() {
    let endpoint = GLMEndpoint(model: "glm-5.2", apiKey: "token")

    #expect(endpoint.providerID == "zhipu")
    #expect(endpoint.baseURL.absoluteString == "https://open.bigmodel.cn/api/paas/v4")

    var headers = RequestHeaders()
    endpoint.modifyHeaders(&headers, options: RequestOptions())
    #expect(headers.sensitiveValues["authorization"] == "Bearer token")
    #expect(Set(headers.sensitiveValues.keys) == ["authorization"])
  }

  @Test func glmPreservationSendsClearThinkingFalseAndReplaysReasoningVerbatim() async throws {
    let endpoint = GLMEndpoint(model: "glm-5.2", apiKey: "token", preserveThinking: true)
    let body = try await emittedBody(endpoint, historyWithReasoning)

    #expect(body["thinking"] == .object([
      "type": .string("enabled"),
      "clear_thinking": .bool(false),
    ]))

    let assistants = assistantMessages(body)
    #expect(assistants.count == 1)
    #expect(assistants[0]["reasoning_content"] == .string("王允在试探我。"))
    #expect(assistants[0]["content"] == .string("妾身明白。"))
    #expect(body["messages"]?.array?.count == 4)
  }

  @Test func glmWithoutPreservationOmitsClearThinking() async throws {
    let endpoint = GLMEndpoint(model: "glm-5.2", apiKey: "token")
    let body = try await emittedBody(endpoint, historyWithReasoning)

    #expect(body["thinking"] == .object(["type": .string("enabled")]))
  }

  @Test func glmDisabledReasoningSendsDisabledThinking() async throws {
    let endpoint = GLMEndpoint(model: "glm-5.2", apiKey: "token", preserveThinking: true)
    let body = try await emittedBody(
      endpoint,
      historyWithReasoning,
      RequestOptions(reasoning: .none),
    )

    #expect(body["thinking"] == .object(["type": .string("disabled")]))
  }

  // MARK: - Kimi

  @Test func kimiPreservationSendsKeepAllAndDropsTemperature() async throws {
    let endpoint = KimiEndpoint(model: "kimi-k2.6", apiKey: "token", preserveThinking: true)
    let body = try await emittedBody(
      endpoint,
      historyWithReasoning,
      RequestOptions(temperature: 0),
    )

    #expect(body["thinking"] == .object([
      "type": .string("enabled"),
      "keep": .string("all"),
    ]))
    #expect(body["reasoning"] == nil)
    #expect(body["temperature"] == nil)
    #expect(body["max_tokens"] == .integer(16000))
    #expect(assistantMessages(body)[0]["reasoning_content"] == .string("王允在试探我。"))
  }

  @Test func kimiPreservationKeepsExplicitMaxTokens() async throws {
    let endpoint = KimiEndpoint(model: "kimi-k2.6", apiKey: "token", preserveThinking: true)
    let body = try await emittedBody(
      endpoint,
      historyWithReasoning,
      RequestOptions(maxTokens: 32000),
    )

    #expect(body["max_tokens"] == .integer(32000))
  }

  @Test func kimiWithoutPreservationKeepsReasoningToggle() async throws {
    let endpoint = KimiEndpoint(model: "kimi-k2.6", apiKey: "token")
    let body = try await emittedBody(endpoint, historyWithReasoning)

    #expect(body["reasoning"] == .object(["enabled": .bool(true)]))
    #expect(body["thinking"] == nil)
    #expect(body["max_tokens"] == nil)
  }

  @Test func kimiReasoningOffKeepsTemperature() async throws {
    let endpoint = KimiEndpoint(model: "kimi-k2.6", apiKey: "token", preserveThinking: true)
    let body = try await emittedBody(
      endpoint,
      historyWithReasoning,
      RequestOptions(temperature: 0, reasoning: .none),
    )

    #expect(body["reasoning"] == .object(["enabled": .bool(false)]))
    #expect(body["thinking"] == nil)
    #expect(body["temperature"] == .number(0))
  }

  // MARK: - MiniMax

  private func miniMaxBody(
    _ options: RequestOptions,
  ) async throws -> OrderedDictionary<String, JSONValue> {
    let endpoint = MiniMaxEndpoint(model: "MiniMax-M3", apiKey: "token")
    var (_, _, body) = try await buildAnthropicRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: historyWithReasoning,
      options: options,
      acceptsUnsignedThinking: endpoint.acceptsUnsignedThinking,
    )
    endpoint.modifyBody(&body, options: options)
    return body
  }

  @Test func miniMaxAsksForThinkingByNameWithoutABudget() async throws {
    let body = try await miniMaxBody(RequestOptions(temperature: 0, reasoning: .automatic))

    #expect(body["thinking"] == .object(["type": .string("enabled")]))
  }

  @Test func miniMaxEffortStillAsksForThinking() async throws {
    let body = try await miniMaxBody(RequestOptions(reasoning: .effort("high")))

    #expect(body["thinking"] == .object(["type": .string("enabled")]))
  }

  @Test func miniMaxReplaysReasoningAsAnUnsignedThinkingBlock() async throws {
    let body = try await miniMaxBody(RequestOptions(temperature: 0, reasoning: .automatic))

    let thinking = anthropicAssistantBlocks(body).filter { $0["type"] == .string("thinking") }
    #expect(thinking.count == 1)
    #expect(thinking[0]["thinking"] == .string(marker))
    #expect(thinking[0]["signature"] == nil)
  }

  @Test func miniMaxReasoningOffDisablesThinking() async throws {
    let body = try await miniMaxBody(RequestOptions(reasoning: .none))

    #expect(body["thinking"] == .object(["type": .string("disabled")]))
  }

  // MARK: - DeepSeek

  @Test func deepSeekChatReplaysCallerReasoningWithoutInventingMessages() async throws {
    let endpoint = DeepSeekChatEndpoint(model: "deepseek-v4-pro", apiKey: "token")
    let body = try await emittedBody(endpoint, historyWithReasoning)

    let messages = body["messages"]?.array?.compactMap(\.object) ?? []
    #expect(messages.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "user"])
    #expect(messages[2]["reasoning_content"] == .string("王允在试探我。"))
    #expect(!messages.contains { $0["role"] == .string("tool") })
    #expect(body["tools"] == nil)
  }

  // MARK: - Cross-dialect replay invariant

  // Clear reasoning must land in the target wire's reasoning channel, degrade to
  // plain text where that wire has none, and never be laundered into speech.

  @Test func stockAnthropicEndpointRejectsUnsignedThinkingAndTheRestAcceptIt() {
    #expect(AnthropicEndpoint(model: "claude-sonnet-4-6", apiKey: "k").acceptsUnsignedThinking == false)
    #expect(DeepSeekAnthropicEndpoint(model: "deepseek-v4-pro", apiKey: "k").acceptsUnsignedThinking)
    #expect(MiniMaxEndpoint(model: "minimax-m2", apiKey: "k").acceptsUnsignedThinking)
  }

  @Test func chatCompletionsReplaysIntoReasoningContent() async throws {
    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "deepseek-v4-pro",
      baseURL: URL(string: "https://api.deepseek.com/v1")!,
      context: historyWithReasoning,
      options: RequestOptions(),
      mediaResolver: nil,
    )

    let assistant = assistantMessages(body)[0]
    #expect(assistant["reasoning_content"] == .string(marker))
    #expect(assistant["content"] != .string(marker))
  }

  @Test func geminiReplaysIntoAThoughtPart() async throws {
    let (_, _, body) = try await buildGeminiRequest(
      model: "gemini-3-flash",
      baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
      context: historyWithReasoning,
      options: RequestOptions(),
    )

    let parts = (body["contents"]?.array ?? [])
      .compactMap(\.object)
      .filter { $0["role"] == .string("model") }
      .flatMap { ($0["parts"]?.array ?? []).compactMap(\.object) }

    let thoughts = parts.filter { $0["thought"] == .bool(true) }
    #expect(thoughts.count == 1)
    #expect(thoughts[0]["text"] == .string(marker))
    #expect(!parts.contains { $0["thought"] == nil && $0["text"] == .string(marker) })
  }

  private var marker: String { "王允在试探我。" }

  private func anthropicAssistantBlocks(
    _ body: OrderedDictionary<String, JSONValue>,
  ) -> [OrderedDictionary<String, JSONValue>] {
    (body["messages"]?.array ?? [])
      .compactMap(\.object)
      .filter { $0["role"] == .string("assistant") }
      .flatMap { ($0["content"]?.array ?? []).compactMap(\.object) }
  }

  // MARK: - Streaming

  @Test func streamSurfacesReasoningDeltasBeforeContentDeltas() async throws {
    let events = try await collect(glmReasoningSSE)

    #expect(events.map(kind) == [
      "start",
      "reasoningStart", "reasoningDelta", "reasoningDelta", "reasoningEnd",
      "textStart", "textDelta", "textDelta", "usage", "textEnd",
      "done",
    ])

    let reasoningDeltas = events.compactMap { event -> String? in
      if case let .reasoningDelta(_, delta, _) = event { return delta }
      return nil
    }
    #expect(reasoningDeltas.joined() == "王允在试探我。")

    let textDeltas = events.compactMap { event -> String? in
      if case let .textDelta(_, delta, _) = event { return delta }
      return nil
    }
    #expect(textDeltas.joined() == "妾身明白。")
  }

  @Test func streamAssemblesFinalMessageWithReasoningAndContent() async throws {
    let events = try await collect(glmReasoningSSE)

    guard case let .done(message, metadata) = try #require(events.last) else {
      Issue.record("expected a done terminal")
      return
    }
    #expect(metadata.stopReason == .stop)
    #expect(metadata.usage?.outputTokens == 24)

    #expect(message.content.count == 2)
    guard case let .reasoning(.unencrypted(reasoning)) = message.content[0] else {
      Issue.record("expected reasoning as the first block")
      return
    }
    #expect(reasoning == "王允在试探我。")
    guard case let .text(text) = message.content[1] else {
      Issue.record("expected text as the second block")
      return
    }
    #expect(text.text == "妾身明白。")
  }

  @Test func reasoningBlockClosesBeforeAToolCallOpens() async throws {
    let events = try await collect(reasoningThenToolCallSSE)

    #expect(events.map(kind) == [
      "start",
      "reasoningStart", "reasoningDelta", "reasoningEnd",
      "toolCallStart", "toolCallEnd",
      "done",
    ])
  }

  // MARK: - Stream helpers

  private func collect(_ payloads: [String]) async throws -> [InferenceEvent] {
    let sse = AsyncThrowingStream<SSEEvent, any Error> { continuation in
      for payload in payloads { continuation.yield(SSEEvent(data: payload)) }
      continuation.finish()
    }
    var events: [InferenceEvent] = []
    for try await event in parseChatCompletionsStream(sse, providerID: "zhipu", model: "glm-5.2") {
      events.append(event)
    }
    return events
  }

  private func kind(_ event: InferenceEvent) -> String {
    switch event {
    case .start: "start"
    case .textStart: "textStart"
    case .textDelta: "textDelta"
    case .textEnd: "textEnd"
    case .reasoningStart: "reasoningStart"
    case .reasoningDelta: "reasoningDelta"
    case .reasoningEnd: "reasoningEnd"
    case .toolCallStart: "toolCallStart"
    case .toolCallDelta: "toolCallDelta"
    case .toolCallEnd: "toolCallEnd"
    case .done: "done"
    case .usage: "usage"
    }
  }
}

// MARK: - Canned wire fixtures

private let glmReasoningSSE = [
  #"{"id":"2026072901","created":1785000000,"model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
  #"{"id":"2026072901","created":1785000000,"model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"王允"}}]}"#,
  #"{"id":"2026072901","created":1785000000,"model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"在试探我。"}}]}"#,
  #"{"id":"2026072901","created":1785000000,"model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","content":"妾身"}}]}"#,
  #"{"id":"2026072901","created":1785000000,"model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","content":"明白。"}}]}"#,
  #"{"id":"2026072901","created":1785000000,"model":"glm-5.2","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":31,"completion_tokens":24,"total_tokens":55}}"#,
  "[DONE]",
]

private let reasoningThenToolCallSSE = [
  #"{"id":"2026072902","model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"该查一下。"}}]}"#,
  #"{"id":"2026072902","model":"glm-5.2","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"貂蝉\"}"}}]}}]}"#,
  #"{"id":"2026072902","model":"glm-5.2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
  "[DONE]",
]
