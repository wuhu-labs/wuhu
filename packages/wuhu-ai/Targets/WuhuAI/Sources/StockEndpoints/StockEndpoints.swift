import Fetch
import Foundation
import JSONValue
import OrderedCollections

// Each stock endpoint is a provider configuration that conforms to the dialect
// protocol for its wire protocol, supplying its provider-specific body/header
// tweaks via the `modifyBody`/`modifyHeaders` hooks. The dialect protocol
// provides `runInference`.

// MARK: - OpenAI GPT Endpoint

public struct OpenAIGPTEndpoint: ResponsesEndpoint {
  public let providerID: String = "openai"
  public let model: String
  public let baseURL: URL

  public var apiKey: String
  public var promptCacheKey: String?
  public var cacheRetention: CacheRetention
  public var verbosity: ResponseVerbosity?

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.openai.com/v1")!,
    apiKey: String,
    promptCacheKey: String? = nil,
    cacheRetention: CacheRetention = .short,
    verbosity: ResponseVerbosity? = nil,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.promptCacheKey = promptCacheKey
    self.cacheRetention = cacheRetention
    self.verbosity = verbosity
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    if let key = promptCacheKey {
      body["prompt_cache_key"] = .string(key)
    }
    if cacheRetention == .long {
      body["prompt_cache_retention"] = .string("24h")
    }
    if let verbosity {
      var text = body["text"]?.object ?? [:]
      if text["verbosity"] == nil {
        text["verbosity"] = .string(verbosity.rawValue)
      }
      body["text"] = .object(text)
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(apiKey)")
  }
}

// MARK: - OpenAI Codex Endpoint

public struct OpenAICodexEndpoint: ResponsesEndpoint {
  public var isCodex: Bool { true }

  public let providerID: String = "openai-codex"
  public let model: String
  public let baseURL: URL

  public var jwt: String
  public var environment: String?
  public var chatgptAccountID: String?
  /// ChatGPT routes a request to a prompt-cache shard by the `session-id`
  /// header, so every turn of one session has to carry the same value or it
  /// scatters across shards and re-reads the whole prefix. Measured on
  /// gpt-5.6-terra, 5 sessions x 20 turns: 86.9% cached with this header vs
  /// 52-60% with the `conversation_id` header nothing reads. `thread-id` and
  /// the body's `prompt_cache_key` take the same value, as Codex sends them.
  public var sessionID: String?
  public var originator: String?
  public var verbosity: ResponseVerbosity?
  private let responseHeaderObserver: @Sendable ([String: String]) async -> Void

  public init(
    model: String,
    baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
    jwt: String,
    environment: String? = nil,
    chatgptAccountID: String? = nil,
    sessionID: String? = nil,
    originator: String? = nil,
    verbosity: ResponseVerbosity? = nil,
    receiveResponseHeaders: @escaping @Sendable ([String: String]) async -> Void = { _ in },
  ) {
    self.model = model
    self.baseURL = baseURL
    self.jwt = jwt
    self.environment = environment
    self.chatgptAccountID = chatgptAccountID
    self.sessionID = sessionID
    self.originator = originator
    self.verbosity = verbosity
    responseHeaderObserver = receiveResponseHeaders
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    if let env = environment {
      body["_codex_environment"] = .string(env)
    }
    if let sessionID {
      body["prompt_cache_key"] = .string(sessionID)
    }
    var text = body["text"]?.object ?? [:]
    if text["verbosity"] == nil {
      text["verbosity"] = .string((verbosity ?? .medium).rawValue)
    }
    body["text"] = .object(text)
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(jwt)")
    headers.setSensitive("chatgpt-account-id", chatgptAccountID ?? "")
    if let originator {
      headers.set("originator", originator)
    }
    if let sessionID {
      headers.set("session-id", sessionID)
      headers.set("thread-id", sessionID)
    }
  }
}

extension OpenAICodexEndpoint: ResponsesHeaderReceiving {
  var receiveResponseHeaders: @Sendable ([String: String]) async -> Void { responseHeaderObserver }
}

// MARK: - Anthropic Endpoint

public enum AnthropicPromptCache: Sendable, Hashable {
  case disabled
  case fiveMinutes
  case oneHour
}

public struct AnthropicEndpoint: AnthropicMessagesEndpoint {
  public let providerID: String = "anthropic"
  public let model: String
  public let baseURL: URL
  public let acceptsUnsignedThinking: Bool = false

  public var apiKey: String
  public var promptCache: AnthropicPromptCache

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.anthropic.com")!,
    apiKey: String,
    promptCache: AnthropicPromptCache = .disabled,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.promptCache = promptCache
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    switch options.reasoning {
    case .none:
      break
    case .automatic:
      body["thinking"] = .object([
        "type": .string("adaptive"),
        "display": .string("summarized"),
      ])
    case .effort(let effort):
      body["thinking"] = .object([
        "type": .string("adaptive"),
        "display": .string("summarized"),
      ])
      body["output_config"] = .object([
        "effort": .string(effort),
      ])
    case .budget(let tokens):
      body["thinking"] = .object([
        "type": .string("enabled"),
        "budget_tokens": .integer(tokens),
      ])
    }
    switch promptCache {
    case .disabled:
      break
    case .fiveMinutes:
      body["cache_control"] = .object(["type": .string("ephemeral")])
    case .oneHour:
      body["cache_control"] = .object([
        "type": .string("ephemeral"),
        "ttl": .string("1h"),
      ])
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("x-api-key", apiKey)
    headers.set("anthropic-version", "2023-06-01")
  }
}

// MARK: - DeepSeek Chat Endpoint

public struct DeepSeekChatEndpoint: ChatCompletionsEndpoint {
  public let providerID: String = "deepseek"
  public let model: String
  public let baseURL: URL

  public var apiKey: String
  public var thinkingEnabled: Bool = true

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
    apiKey: String,
    thinkingEnabled: Bool = true,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.thinkingEnabled = thinkingEnabled
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    switch options.reasoning {
    case .none:
      body["thinking"] = .object(["type": .string("disabled")])
    case .automatic:
      body["thinking"] = .object(["type": .string("enabled")])
    case .effort(let effort):
      body["thinking"] = .object(["type": .string("enabled")])
      body["reasoning_effort"] = .string(effort)
    case .budget:
      break
    }
    // DeepSeek's OpenAI dialect rejects every tool_choice forcing form while
    // thinking is on (reasoning XOR forced tool on this dialect).
    if options.toolChoice != .none {
      body["thinking"] = .object(["type": .string("disabled")])
      body["reasoning_effort"] = nil
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(apiKey)")
  }
}

// MARK: - DeepSeek Anthropic Endpoint

public struct DeepSeekAnthropicEndpoint: AnthropicMessagesEndpoint {
  public let providerID: String = "deepseek"
  public let model: String
  public let baseURL: URL

  public var apiKey: String

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.deepseek.com/anthropic")!,
    apiKey: String,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    switch options.reasoning {
    case .none:
      break
    case .automatic:
      body["thinking"] = .object(["type": .string("enabled")])
    case .effort(let effort):
      body["thinking"] = .object(["type": .string("enabled")])
      body["output_config"] = .object(["effort": .string(effort)])
    case .budget(let tokens):
      body["thinking"] = .object([
        "type": .string("enabled"),
        "budget_tokens": .integer(tokens),
      ])
    }
    // DeepSeek dialect divergence (2026-07-05 research note): a named forced
    // tool is rejected while thinking is on; tool_choice {type:"any"} works
    // with thinking. Disable thinking for named-force turns only.
    if case .tool = options.toolChoice {
      body["thinking"] = .object(["type": .string("disabled")])
      body["output_config"] = nil
    }
    // Under thinking, DeepSeek rejects a tool_use turn that carries no thinking
    // block ("content[].thinking ... must be passed back"). The block's text is
    // never read back — an empty one satisfies the check — so turns generated
    // thinking-off, and fabricated ones, get a placeholder rather than costing
    // the request its reasoning.
    if body["thinking"]?.object?["type"]?.stringValue == "enabled",
       let messages = body["messages"]?.array
    {
      body["messages"] = .array(messages.map(placeholderThinkingForToolUse))
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(apiKey)")
    headers.set("anthropic-version", "2023-06-01")
  }
}

private func placeholderThinkingForToolUse(_ message: JSONValue) -> JSONValue {
  guard var object = message.object,
        object["role"]?.stringValue == "assistant",
        let content = object["content"]?.array,
        content.contains(where: { $0.object?["type"]?.stringValue == "tool_use" }),
        !content.contains(where: {
          let type = $0.object?["type"]?.stringValue
          return type == "thinking" || type == "redacted_thinking"
        })
  else { return message }
  object["content"] = .array([.object(["type": .string("thinking"), "thinking": .string("")])] + content)
  return .object(object)
}

// MARK: - Gemini Endpoint

public struct GeminiEndpoint: GeminiContentEndpoint {
  public let providerID: String = "gemini"
  public let model: String
  public let baseURL: URL

  public var apiKey: String

  public init(
    model: String,
    baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
    apiKey: String,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    var thinkingConfig: OrderedDictionary<String, JSONValue> = [
      "includeThoughts": .bool(true),
    ]
    switch options.reasoning {
    case .none:
      thinkingConfig["thinkingBudget"] = .integer(0)
    case .automatic:
      break
    case .effort(let effort):
      thinkingConfig["thinkingBudget"] = .integer(mapGeminiEffortToBudget(effort))
    case .budget(let tokens):
      thinkingConfig["thinkingBudget"] = .integer(tokens)
    }
    var gc = body["generationConfig"]?.object ?? [:]
    gc["thinkingConfig"] = .object(thinkingConfig)
    body["generationConfig"] = .object(gc)
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("x-goog-api-key", apiKey)
  }
}

private func mapGeminiEffortToBudget(_ effort: String) -> Int {
  switch effort.lowercased() {
  case "minimal": return 256
  case "low": return 512
  case "medium": return 1024
  case "high": return 2048
  case "xhigh": return 8192
  default: return 1024
  }
}

// MARK: - Kimi Endpoint

public struct KimiEndpoint: ChatCompletionsEndpoint {
  public let providerID: String = "kimi"
  public let model: String
  public let baseURL: URL

  public var apiKey: String
  public var preserveThinking: Bool

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.moonshot.cn/v1")!,
    apiKey: String,
    preserveThinking: Bool = false,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.preserveThinking = preserveThinking
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    if case .none = options.reasoning {
      body["reasoning"] = .object(["enabled": .bool(false)])
      return
    }
    if preserveThinking {
      // Moonshot only replays historical `reasoning_content` under keep:"all";
      // the `reasoning` knob does not carry it.
      body["thinking"] = .object([
        "type": .string("enabled"),
        "keep": .string("all"),
      ])
      if body["max_tokens"] == nil {
        body["max_tokens"] = .integer(kimiThinkingMaxTokensFloor)
      }
    } else {
      body["reasoning"] = .object(["enabled": .bool(true)])
    }
    // Thinking mode pins temperature at 1.0 and 400s on any other value.
    body["temperature"] = nil
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(apiKey)")
  }
}

private let kimiThinkingMaxTokensFloor = 16000

// MARK: - GLM (Zhipu) Endpoint

public struct GLMEndpoint: ChatCompletionsEndpoint {
  public let providerID: String = "zhipu"
  public let model: String
  public let baseURL: URL

  public var apiKey: String
  public var preserveThinking: Bool

  public init(
    model: String,
    baseURL: URL = URL(string: "https://open.bigmodel.cn/api/paas/v4")!,
    apiKey: String,
    preserveThinking: Bool = false,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.preserveThinking = preserveThinking
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    if case .none = options.reasoning {
      body["thinking"] = .object(["type": .string("disabled")])
      return
    }
    var thinking: OrderedDictionary<String, JSONValue> = ["type": .string("enabled")]
    if preserveThinking {
      // GLM replays historical `reasoning_content` only under this flag; the
      // default and clear_thinking:true both drop it.
      thinking["clear_thinking"] = .bool(false)
    }
    body["thinking"] = .object(thinking)
    if case let .effort(effort) = options.reasoning {
      body["reasoning_effort"] = .string(effort)
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(apiKey)")
  }
}

// MARK: - Qwen Endpoint

public struct QwenEndpoint: ChatCompletionsEndpoint {
  public let providerID: String = "qwen"
  public let model: String
  public let baseURL: URL

  public var apiKey: String
  public var preserveThinking: Bool = false

  public init(
    model: String,
    baseURL: URL = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
    apiKey: String,
    preserveThinking: Bool = false,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.preserveThinking = preserveThinking
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    switch options.reasoning {
    case .none:
      body["enable_thinking"] = .bool(false)
    case .automatic:
      body["enable_thinking"] = .bool(true)
    case .effort:
      body["enable_thinking"] = .bool(true)
    case .budget:
      body["enable_thinking"] = .bool(true)
    }
    if preserveThinking {
      body["preserve_thinking"] = .bool(true)
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(apiKey)")
  }
}

// MARK: - MiniMax Endpoint

public struct MiniMaxEndpoint: AnthropicMessagesEndpoint {
  public let providerID: String = "minimax"
  public let model: String
  public let baseURL: URL

  public var apiKey: String

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.minimaxi.com/anthropic")!,
    apiKey: String,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    switch options.reasoning {
    case .none:
      body["thinking"] = .object(["type": .string("disabled")])
    case .automatic, .effort:
      // MiniMax emits no thinking blocks at all unless thinking is asked for by
      // name; unlike Anthropic proper it accepts `enabled` without a budget.
      body["thinking"] = .object(["type": .string("enabled")])
    case .budget(let tokens):
      body["thinking"] = .object([
        "type": .string("enabled"),
        "budget_tokens": .integer(tokens),
      ])
    }
  }

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("x-api-key", apiKey)
  }
}

// MARK: - ModelEndpoint Convenience Factories

extension ModelEndpoint {
  public static func openAIResponses(model: String, apiKey: String) -> OpenAIGPTEndpoint {
    OpenAIGPTEndpoint(model: model, apiKey: apiKey)
  }

  public static func openAICodex(
    model: String,
    jwt: String,
    environment: String? = nil,
    originator: String? = nil,
  ) -> OpenAICodexEndpoint {
    OpenAICodexEndpoint(model: model, jwt: jwt, environment: environment, originator: originator)
  }

  public static func anthropic(model: String, apiKey: String) -> AnthropicEndpoint {
    AnthropicEndpoint(model: model, apiKey: apiKey)
  }

  public static func deepSeekChat(
    model: String,
    apiKey: String,
    thinkingEnabled: Bool = true,
  ) -> DeepSeekChatEndpoint {
    DeepSeekChatEndpoint(model: model, apiKey: apiKey, thinkingEnabled: thinkingEnabled)
  }

  public static func deepSeekAnthropic(model: String, apiKey: String) -> DeepSeekAnthropicEndpoint {
    DeepSeekAnthropicEndpoint(model: model, apiKey: apiKey)
  }

  public static func gemini(model: String, apiKey: String) -> GeminiEndpoint {
    GeminiEndpoint(model: model, apiKey: apiKey)
  }

  public static func kimi(
    model: String,
    apiKey: String,
    preserveThinking: Bool = false,
  ) -> KimiEndpoint {
    KimiEndpoint(model: model, apiKey: apiKey, preserveThinking: preserveThinking)
  }

  public static func glm(
    model: String,
    apiKey: String,
    preserveThinking: Bool = false,
  ) -> GLMEndpoint {
    GLMEndpoint(model: model, apiKey: apiKey, preserveThinking: preserveThinking)
  }

  public static func qwen(
    model: String,
    apiKey: String,
    preserveThinking: Bool = false,
  ) -> QwenEndpoint {
    QwenEndpoint(model: model, apiKey: apiKey, preserveThinking: preserveThinking)
  }

  public static func miniMax(model: String, apiKey: String) -> MiniMaxEndpoint {
    MiniMaxEndpoint(model: model, apiKey: apiKey)
  }
}
