import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Synchronization
import Testing
import WuhuAI

@Suite struct ReplayScopeContractTests {
  @Test(arguments: ["account-a", "account-b", nil] as [String?])
  func anthropicSignaturesAndRedactedBlocksRequireExactKnownScope(target: String?) async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", replayScope: target, apiKey: "offline")
    let context = history(provider: "anthropic")
    let body = try await emitted(endpoint, context: context)
    let serialized = body.jsonString()
    if target == "account-a" {
      #expect(serialized.contains("signed-secret"))
      #expect(serialized.contains("redacted-secret"))
      #expect(serialized.contains("redacted_thinking"))
    } else {
      #expect(!serialized.contains("signed-secret"))
      #expect(!serialized.contains("redacted-secret"))
      #expect(!serialized.contains("thinking"))
      #expect(serialized.contains("readable summary"))
    }
  }

  @Test(arguments: ["account-a", "account-b", nil] as [String?])
  func responsesGatewayDropsEntireNativeOpaqueItems(target: String?) async throws {
    let endpoint = OpenAIGPTEndpoint(model: "claude-gateway", replayScope: target, baseURL: URL(string: "https://gateway.invalid/v1")!, apiKey: "offline")
    let body = try await emitted(endpoint, context: history(provider: "openai"))
    let text = body.jsonString()
    #expect(text.contains("readable summary"))
    #expect(text.contains("rs_native") == (target == "account-a"))
    #expect(text.contains("signed-secret") == (target == "account-a"))
    #expect(!text.contains("hidden-gateway-summary"), "Never decode opaque gateway JSON into portable text")
  }

  @Test(arguments: ["account-a", "account-b", nil] as [String?])
  func codexHostedRecordsUseOnlySafeDigestOutsideScope(target: String?) async throws {
    let payload = try #require(JSONValue.parse(#"{"id":"ws_native","type":"web_search_call","status":"completed","action":{"type":"search","queries":["private query"],"secret":"nested-secret"}}"#))
    let item = try #require(HostedToolContent(providerID: "openai-codex", payload: payload, replayScope: "account-a"))
    let endpoint = OpenAICodexEndpoint(model: "codex-test", replayScope: target, jwt: "offline")
    let body = try await emitted(endpoint, context: Context(messages: [.assistant(.init(content: [.hostedTool(item)]))]))
    let text = body.jsonString()
    #expect(text.contains("ws_native") == (target == "account-a"))
    #expect(text.contains("nested-secret") == (target == "account-a"))
    #expect(text.contains("private query") == (target == "account-a"))
    if target != "account-a" { #expect(text.contains("web_search_call · search")) }
  }

  @Test func unknownLegacyScopeDoesNotBecomeCurrentAccount() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", replayScope: "account-a", apiKey: "offline")
    let context = Context(messages: [.assistant(.init(content: [
      .reasoning(.encrypted(.init(providerID: "anthropic", model: "claude-test", summary: "legacy summary", opaque: "legacy-signature"))),
      .text("answer"),
    ]))])
    let body = try await emitted(endpoint, context: context)
    #expect(body.jsonString().contains("legacy summary"))
    #expect(!body.jsonString().contains("legacy-signature"))
  }

  @Test func noOpaqueAnthropicThinkingIsSentAndToolLoopStaysValid() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", apiKey: "offline")
    let thinking = try await emittedRequest(endpoint, context: toolHistory(), options: .init(reasoning: .effort("high")))
    #expect(thinking.body.object?["thinking"]?.object?["type"] == .string("adaptive"), "No replay scope is not a reason to refuse; the upstream judges the request")
    #expect(!thinking.body.jsonString().contains("signed-secret"))
    let body = try await emitted(endpoint, context: toolHistory())
    #expect(body.object?["thinking"] == nil)
    let messages = try #require(body.object?["messages"]?.array)
    #expect(messages.count == 3)
    #expect(messages[1].object?["content"]?.array?.contains { $0.object?["type"] == .string("tool_use") } == true)
    #expect(messages[2].object?["content"]?.array?.first?.object?["tool_use_id"] == .string("kernel-call"))
    #expect(!body.jsonString().contains("signed-secret"))
  }

  @Test func crossScopeToolHistoryIsSentWithSignaturesStripped() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", replayScope: "account-b", apiKey: "offline")
    let request = try await emittedRequest(endpoint, context: toolHistory(), options: .init(reasoning: .effort("high")))
    #expect(request.body.object?["thinking"]?.object?["type"] == .string("adaptive"))
    let assistant = try #require(request.body.object?["messages"]?.array?[1].object?["content"]?.array)
    #expect(assistant.first?.object?["type"] == .string("text"))
    #expect(assistant.first?.object?["text"] == .string("readable summary"))
    #expect(assistant.last?.object?["type"] == .string("tool_use"))
    #expect(!request.body.jsonString().contains("signed-secret"))
    #expect(!request.body.jsonString().contains("signature"))
  }

  @Test func unsignedThinkingReplaysAsPlainThinkingInEveryToolStep() async throws {
    // MiMo shape: readable thinking with an empty signature before each tool call.
    let endpoint = AnthropicEndpoint(model: "mimo-test", replayScope: "account-a", baseURL: URL(string: "https://mimo.invalid/anthropic")!, apiKey: "offline")
    var messages: [Message] = [.user(.init(content: [.text("start")]))]
    for step in 1 ... 4 {
      messages.append(.assistant(.init(content: [
        .reasoning(.encrypted(.init(providerID: "anthropic", model: "mimo-test", summary: "step \(step) thinking", opaque: "", replayScope: "account-a"))),
        .toolCall(.init(id: "call_\(step)", name: "test", arguments: .object([:]))),
      ])))
      messages.append(.toolResult(.init(toolCallId: "call_\(step)", content: [.text("result")])))
      if step.isMultiple(of: 2) { messages.append(.user(.init(content: [.text("context notice \(step)")]))) }
    }
    let request = try await emittedRequest(endpoint, context: Context(messages: messages, tools: [.init(name: "test", description: "test", parameters: .object(["type": .string("object")]))]), options: .init(reasoning: .effort("high")))
    #expect(request.body.object?["thinking"]?.object?["type"] == .string("adaptive"))
    let assistants = try #require(request.body.object?["messages"]?.array).filter { $0.object?["role"] == .string("assistant") }
    #expect(assistants.count == 4)
    for (index, assistant) in assistants.enumerated() {
      let first = assistant.object?["content"]?.array?.first?.object
      #expect(first?["type"] == .string("thinking"))
      #expect(first?["thinking"] == .string("step \(index + 1) thinking"))
      #expect(first?["signature"] == nil)
    }
  }

  @Test func cacheAndCodexThreadIdentityRotateWithScopeAndEpoch() async throws {
    var keys: [String] = []
    for (scope, epoch) in [("account-a", "1"), ("account-a", "1"), ("account-b", "1"), ("account-b", "2")] {
      let endpoint = OpenAICodexEndpoint(model: "codex-test", replayScope: scope, routeEpoch: epoch, jwt: "offline", sessionID: "stable-session")
      let captured = try await emittedRequest(endpoint, context: Context(messages: []))
      let key = try #require(captured.body.object?["prompt_cache_key"]?.stringValue)
      keys.append(key)
      #expect(captured.headers["session-id"] == key)
      #expect(captured.headers["thread-id"] == key)
      #expect(!key.contains(scope) && !key.contains("stable-session"))
    }
    #expect(keys[0] == keys[1])
    #expect(keys[1] != keys[2])
    #expect(keys[2] != keys[3])
    let first = try await emitted(OpenAIGPTEndpoint(model: "gpt-test", replayScope: "account-a", routeEpoch: "1", apiKey: "offline", promptCacheKey: "session"), context: Context(messages: []))
    let second = try await emitted(OpenAIGPTEndpoint(model: "gpt-test", replayScope: "account-a", routeEpoch: "2", apiKey: "offline", promptCacheKey: "session"), context: Context(messages: []))
    #expect(first.object?["prompt_cache_key"] != second.object?["prompt_cache_key"])
  }

  @Test func parserStampsEndpointScopeAndCodablePreservesIt() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", replayScope: "account-a", apiKey: "offline")
    let message = try await withDependencies {
      $0.fetch = FetchClient { _ in Response(status: .ok, body: .string(anthropicSignedResponse)) }
    } operation: {
      try await endpoint.inference(context: Context(messages: []), options: .init(reasoning: .none)).collect()
    }
    guard case let .reasoning(.encrypted(reasoning)) = message.content.first else { Issue.record("Missing reasoning"); return }
    #expect(reasoning.replayScope == "account-a")
    let decoded = try JSONDecoder().decode(AssistantMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded == message)
  }

  @Test func sameScopeSurvivesOAuthRefreshWithoutTreatingBearerAsScope() async throws {
    let payload = try #require(JSONValue.parse(#"{"id":"ws_native","type":"web_search_call","action":{"type":"search"}}"#))
    let hosted = try #require(HostedToolContent(providerID: "openai-codex", payload: payload, replayScope: "account-a"))
    var context = history(provider: "openai-codex")
    context.messages.append(.assistant(.init(content: [.hostedTool(hosted)])))
    let first = OpenAICodexEndpoint(model: "codex-test", replayScope: "account-a", routeEpoch: "1", jwt: "old-access-token", sessionID: "session")
    var refreshed = first
    refreshed.jwt = "refreshed-access-token"
    let firstRequest = try await emittedRequest(first, context: context)
    let nextRequest = try await emittedRequest(refreshed, context: context)
    #expect(firstRequest.body == nextRequest.body)
    #expect(nextRequest.body.jsonString().contains("signed-secret"))
    #expect(nextRequest.body.jsonString().contains("ws_native"))
  }

  @Test func responsesSSEStampsHostedAndEncryptedScopeAndRoundTripsLegacy() async throws {
    let endpoint = OpenAICodexEndpoint(model: "codex-test", replayScope: "account-a", jwt: "offline")
    let events = [
      #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_scope","summary":[],"encrypted_content":"opaque"}}"#,
      #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_scope","summary":[],"encrypted_content":"opaque"}}"#,
      #"{"type":"response.output_item.done","item":{"type":"web_search_call","id":"ws_scope","status":"completed","action":{"type":"search"}}}"#,
      #"{"type":"response.completed","response":{"id":"resp_scope","status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":2}}}"#,
    ].map { "data: \($0)\n\n" }.joined()
    let message = try await withDependencies {
      $0.fetch = FetchClient { _ in Response(status: .ok, body: .string(events)) }
    } operation: {
      try await endpoint.inference(context: Context(messages: [])).collect()
    }
    #expect(message.content.count == 2)
    for block in message.content {
      switch block {
      case let .reasoning(.encrypted(item)): #expect(item.replayScope == "account-a")
      case let .hostedTool(item): #expect(item.replayScope == "account-a")
      default: Issue.record("Unexpected output")
      }
    }
    #expect(try JSONDecoder().decode(AssistantMessage.self, from: JSONEncoder().encode(message)) == message)
    let old = Data(#"{"provider_id":"anthropic","model":"claude","opaque":"old","redacted":false}"#.utf8)
    guard case let .encrypted(reasoning) = try JSONDecoder().decode(ReasoningContent.self, from: old) else { Issue.record("Missing legacy reasoning"); return }
    #expect(reasoning.replayScope == nil)
  }

  @Test func hostedDigestDoesNotTrustArbitraryTypeOrActionStrings() async throws {
    let payload = try #require(JSONValue.parse(#"{"id":"native-secret","type":"secret-type","action":{"type":"secret-action"}}"#))
    let item = try #require(HostedToolContent(providerID: "openai-codex", payload: payload, replayScope: "account-a"))
    let endpoint = OpenAICodexEndpoint(model: "codex-test", replayScope: "account-b", jwt: "offline")
    let body = try await emitted(endpoint, context: Context(messages: [.assistant(.init(content: [.hostedTool(item)]))]))
    #expect(body.jsonString().contains("hosted_tool · unknown"))
    #expect(!body.jsonString().contains("secret"))
  }

  @Test func scopeContractSurvivesFactoriesAndDecorators() {
    let endpoint = AnthropicEndpoint.anthropic(model: "claude-test", replayScope: "account-a", routeEpoch: "1", apiKey: "offline")
    let wrapped = endpoint.withFetch(FetchClient { _ in throw FetchError.unimplemented })
    #expect(wrapped.replayScope == "account-a")
    #expect(wrapped.routeEpoch == "1")
    #expect(AnthropicEndpoint(model: "claude-test", apiKey: "offline").replayScope == nil)
  }

  @Test func signedSameScopeThinkingToolContinuationRemainsValid() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", replayScope: "account-a", apiKey: "offline")
    let request = try await emittedRequest(endpoint, context: toolHistory(), options: .init(reasoning: .effort("high")))
    #expect(request.body.object?["thinking"]?.object?["type"] == .string("adaptive"))
    let assistant = try #require(request.body.object?["messages"]?.array?[1].object)
    #expect(assistant["content"]?.array?.first?.object?["signature"] == .string("signed-secret"))
  }

  @Test func portableCompletedToolTailThenFreshHandoffStartsValidThinkingTurn() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", replayScope: "account-b", apiKey: "offline")
    var context = toolHistory()
    context.messages.append(.user(.init(content: [.text("Fresh account-neutral handoff. Continue the outstanding input; the preceding tool receipts are completed history.")])))
    let request = try await emittedRequest(endpoint, context: context, options: .init(reasoning: .effort("high")))
    #expect(request.body.object?["thinking"]?.object?["type"] == .string("adaptive"))
    let messages = try #require(request.body.object?["messages"]?.array)
    #expect(messages.count == 4)
    let oldAssistant = try #require(messages[1].object?["content"]?.array)
    #expect(oldAssistant.first?.object?["type"] == .string("text"))
    #expect(oldAssistant.first?.object?["text"] == .string("readable summary"))
    #expect(oldAssistant.last?.object?["type"] == .string("tool_use"))
    #expect(messages[2].object?["content"]?.array?.first?.object?["tool_use_id"] == .string("kernel-call"))
    #expect(messages[3].object?["role"] == .string("user"))
    #expect(messages[3].object?["content"]?.array?.first?.object?["text"]?.stringValue?.hasPrefix("Fresh account-neutral handoff") == true)
    #expect(!request.body.jsonString().contains("signed-secret"))
  }

  private func history(provider: String) -> Context {
    Context(messages: [.assistant(.init(content: [
      .reasoning(.encrypted(.init(providerID: provider, model: "test", summary: "readable summary", opaque: "signed-secret", id: "rs_native", replayScope: "account-a"))),
      .reasoning(.encrypted(.init(providerID: provider, model: "test", opaque: "redacted-secret", redacted: true, replayScope: "account-a"))),
      .reasoning(.encrypted(.init(providerID: provider, model: "test", opaque: #"{"summary":"hidden-gateway-summary"}"#, id: "rs_gateway", replayScope: "account-other"))),
      .text("answer"),
    ]))])
  }

  private func toolHistory() -> Context {
    Context(messages: [
      .user(.init(content: [.text("start")])),
      .assistant(.init(content: [
        .reasoning(.encrypted(.init(providerID: "anthropic", model: "test", summary: "readable summary", opaque: "signed-secret", replayScope: "account-a"))),
        .toolCall(.init(id: "kernel-call", name: "test", arguments: .object([:]))),
      ])),
      .toolResult(.init(toolCallId: "kernel-call", content: [.text("result")])),
    ], tools: [.init(name: "test", description: "test", parameters: .object(["type": .string("object")]))])
  }

  private func emitted(_ endpoint: some ModelEndpoint, context: Context) async throws -> JSONValue {
    try await emittedRequest(endpoint, context: context).body
  }

  private func emittedRequest(_ endpoint: some ModelEndpoint, context: Context, options: RequestOptions = .init(reasoning: .none)) async throws -> CapturedRequest {
    let capture = Mutex<CapturedRequest?>(nil)
    await withDependencies {
      $0.fetch = FetchClient { request in
        let body = try #require(JSONValue.parse(try await request.body?.text() ?? ""))
        capture.withLock { $0 = CapturedRequest(body: body, headers: request.headers.values) }
        throw FetchError.unimplemented
      }
    } operation: {
      do { _ = try await endpoint.inference(context: context, options: options).collect() }
      catch {}
    }
    return try #require(capture.withLock { $0 })
  }
}

private struct CapturedRequest: Sendable {
  var body: JSONValue
  var headers: [String: String]
}

private let anthropicSignedResponse = """
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_start
data: {"index":0,"content_block":{"type":"thinking","thinking":"summary","signature":"sig"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {}

"""
