import Foundation

public enum Provider: String, Sendable {
  case openai
  case openaiCodex = "openai-codex"
  case anthropic
}

public struct Model: Sendable, Hashable {
  public var id: String
  public var provider: Provider
  public var baseURL: URL

  public init(id: String, provider: Provider, baseURL: URL? = nil) {
    self.id = id
    self.provider = provider

    if let baseURL {
      self.baseURL = baseURL
      return
    }

    switch provider {
    case .openai:
      self.baseURL = URL(string: "https://api.openai.com/v1")!
    case .openaiCodex:
      self.baseURL = URL(string: "https://chatgpt.com/backend-api")!
    case .anthropic:
      self.baseURL = URL(string: "https://api.anthropic.com/v1")!
    }
  }
}

public struct Context: Sendable, Hashable {
  public var systemPrompt: String?
  public var messages: [ChatMessage]

  public init(systemPrompt: String? = nil, messages: [ChatMessage]) {
    self.systemPrompt = systemPrompt
    self.messages = messages
  }
}

public struct ChatMessage: Sendable, Hashable {
  public enum Role: String, Sendable, Hashable {
    case user
    case assistant
  }

  public var role: Role
  public var content: String
  public var timestamp: Date

  public init(role: Role, content: String, timestamp: Date = Date()) {
    self.role = role
    self.content = content
    self.timestamp = timestamp
  }
}

public enum StopReason: String, Sendable {
  case stop
  case length
  case toolUse
  case aborted
  case error
}

public struct Usage: Sendable, Hashable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int

  public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
  }
}

public struct RequestOptions: Sendable, Hashable {
  public var temperature: Double?
  public var maxTokens: Int?
  public var apiKey: String?
  public var headers: [String: String]
  public var sessionId: String?

  public init(
    temperature: Double? = nil,
    maxTokens: Int? = nil,
    apiKey: String? = nil,
    headers: [String: String] = [:],
    sessionId: String? = nil,
  ) {
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.apiKey = apiKey
    self.headers = headers
    self.sessionId = sessionId
  }
}

public struct TextContent: Sendable, Hashable {
  public var text: String
  public var signature: String?

  public init(text: String, signature: String? = nil) {
    self.text = text
    self.signature = signature
  }
}

public enum AssistantContent: Sendable, Hashable {
  case text(TextContent)
  case toolCall(ToolCall)
}

public struct AssistantMessage: Sendable, Hashable {
  public var provider: Provider
  public var model: String
  public var content: [AssistantContent]
  public var usage: Usage?
  public var stopReason: StopReason
  public var errorMessage: String?
  public var timestamp: Date

  public init(
    provider: Provider,
    model: String,
    content: [AssistantContent] = [],
    usage: Usage? = nil,
    stopReason: StopReason = .stop,
    errorMessage: String? = nil,
    timestamp: Date = Date(),
  ) {
    self.provider = provider
    self.model = model
    self.content = content
    self.usage = usage
    self.stopReason = stopReason
    self.errorMessage = errorMessage
    self.timestamp = timestamp
  }
}

public enum AssistantMessageEvent: Sendable, Hashable {
  case start(partial: AssistantMessage)
  case textDelta(delta: String, partial: AssistantMessage)
  case done(message: AssistantMessage)
}
