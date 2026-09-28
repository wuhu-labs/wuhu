import Foundation
import JSONValue

// MARK: - ContentBlock

/// A single content block in a message.
public enum ContentBlock: Hashable, Sendable, Codable {
  case text(TextContent)
  case reasoning(ReasoningContent)
  case toolCall(ToolCall)
  case hostedTool(HostedToolContent)
  case media(MediaContent)

  // MARK: Codable

  enum CodingKeys: String, CodingKey {
    case text
    case reasoning
    case toolCall = "tool_call"
    case hostedTool = "hosted_tool"
    case media
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try? container.decode(TextContent.self, forKey: .text) {
      self = .text(value)
    } else if let value = try? container.decode(ReasoningContent.self, forKey: .reasoning) {
      self = .reasoning(value)
    } else if let value = try? container.decode(ToolCall.self, forKey: .toolCall) {
      self = .toolCall(value)
    } else if let value = try? container.decode(HostedToolContent.self, forKey: .hostedTool) {
      self = .hostedTool(value)
    } else {
      let value = try container.decode(MediaContent.self, forKey: .media)
      self = .media(value)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .text(value):
      try container.encode(value, forKey: .text)
    case let .reasoning(value):
      try container.encode(value, forKey: .reasoning)
    case let .toolCall(value):
      try container.encode(value, forKey: .toolCall)
    case let .hostedTool(value):
      try container.encode(value, forKey: .hostedTool)
    case let .media(value):
      try container.encode(value, forKey: .media)
    }
  }
}

extension ContentBlock {
  public static func text(_ text: String) -> ContentBlock {
    .text(.init(text: text))
  }

  public static func inlineImage(_ data: Data, mimeType: String) -> ContentBlock {
    let dataUri = URL(string: "data:\(mimeType);base64,\(data.base64EncodedString())")!
    return .media(.init(url: dataUri, mimeType: mimeType))
  }
}

// MARK: - Block Types

public struct TextContent: Hashable, Sendable, Codable {
  public var text: String

  public init(text: String) {
    self.text = text
  }

  public enum CodingKeys: String, CodingKey {
    case text = "text"
  }
}

// MARK: - ReasoningContent

/// Reasoning content — either unencrypted text or an encrypted provider-specific blob.
public enum ReasoningContent: Hashable, Sendable, Codable {
  case unencrypted(String)
  case encrypted(EncryptedReasoningContent)

  enum CodingKeys: String, CodingKey {
    case unencrypted
    case encrypted
    // EncryptedReasoningContent fields (flattened into ReasoningContent)
    case providerID = "provider_id"
    case model
    case summary
    case opaque
    case id
    case redacted
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let text = try? container.decode(String.self, forKey: .unencrypted) {
      self = .unencrypted(text)
    } else if container.contains(.opaque) || container.contains(.providerID) {
      let content = try EncryptedReasoningContent(
        providerID: container.decode(String.self, forKey: .providerID),
        model: container.decode(String.self, forKey: .model),
        summary: try container.decodeIfPresent(String.self, forKey: .summary),
        opaque: try container.decode(String.self, forKey: .opaque),
        id: try container.decodeIfPresent(String.self, forKey: .id),
        redacted: try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false,
      )
      self = .encrypted(content)
    } else {
      let content = try container.decode(EncryptedReasoningContent.self, forKey: .encrypted)
      self = .encrypted(content)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .unencrypted(text):
      try container.encode(text, forKey: .unencrypted)
    case let .encrypted(content):
      try container.encode(content.providerID, forKey: .providerID)
      try container.encode(content.model, forKey: .model)
      try container.encodeIfPresent(content.summary, forKey: .summary)
      try container.encode(content.opaque, forKey: .opaque)
      try container.encodeIfPresent(content.id, forKey: .id)
      try container.encode(content.redacted, forKey: .redacted)
    }
  }
}

/// Encrypted reasoning content — provider-specific opaque blob with metadata.
public struct EncryptedReasoningContent: Hashable, Sendable, Codable {
  public var providerID: String
  public var model: String
  public var summary: String?
  public var opaque: String
  public var id: String? // Responses item ID for round-tripping
  /// Whether the reasoning was redacted by the provider (e.g. Anthropic `redacted_thinking`).
  /// When `true`, `summary` is always `nil` and no text is available.
  public var redacted: Bool

  public init(
    providerID: String,
    model: String,
    summary: String? = nil,
    opaque: String,
    id: String? = nil,
    redacted: Bool = false,
  ) {
    self.providerID = providerID
    self.model = model
    self.summary = summary
    self.opaque = opaque
    self.id = id
    self.redacted = redacted
  }

  public enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case model = "model"
    case summary = "summary"
    case opaque = "opaque"
    case id = "id"
    case redacted = "redacted"
  }
}

public struct ToolCall: Hashable, Sendable, Codable {
  public var id: String
  public var name: String
  public var arguments: ToolArguments

  public init(id: String, name: String, arguments: ToolArguments) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  public enum CodingKeys: String, CodingKey {
    case id = "id"
    case name = "name"
    case arguments = "arguments"
  }
}

public struct MediaContent: Hashable, Sendable, Codable {
  public var url: URL
  public var mimeType: String

  public init(url: URL, mimeType: String) {
    self.url = url
    self.mimeType = mimeType
  }

  public enum CodingKeys: String, CodingKey {
    case url = "url"
    case mimeType = "mime_type"
  }
}

// MARK: - Message

public enum Message: Hashable, Sendable, Codable {
  case user(UserMessage)
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)

  public var user: UserMessage? {
    if case let .user(m) = self { return m }
    return nil
  }

  public var assistant: AssistantMessage? {
    if case let .assistant(m) = self { return m }
    return nil
  }

  public var toolResult: ToolResultMessage? {
    if case let .toolResult(m) = self { return m }
    return nil
  }

  // MARK: Codable

  enum CodingKeys: String, CodingKey {
    case user
    case assistant
    case toolResult = "tool_result"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try? container.decode(UserMessage.self, forKey: .user) {
      self = .user(value)
    } else if let value = try? container.decode(AssistantMessage.self, forKey: .assistant) {
      self = .assistant(value)
    } else {
      let value = try container.decode(ToolResultMessage.self, forKey: .toolResult)
      self = .toolResult(value)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .user(value):
      try container.encode(value, forKey: .user)
    case let .assistant(value):
      try container.encode(value, forKey: .assistant)
    case let .toolResult(value):
      try container.encode(value, forKey: .toolResult)
    }
  }
}

public struct UserMessage: Hashable, Sendable, Codable {
  public var content: [ContentBlock]

  public init(content: [ContentBlock]) {
    self.content = content
  }

  public enum CodingKeys: String, CodingKey {
    case content = "content"
  }
}

public struct AssistantMessage: Hashable, Sendable, Codable {
  public var content: [ContentBlock]
  /// OpenAI Responses "phase" field — model-output metadata.
  public var phase: AssistantMessagePhase?

  public init(
    content: [ContentBlock] = [],
    phase: AssistantMessagePhase? = nil,
  ) {
    self.content = content
    self.phase = phase
  }

  public enum CodingKeys: String, CodingKey {
    case content = "content"
    case phase = "phase"
  }
}

/// Post-stream metadata for an assistant message.
public struct AssistantMessageMetadata: Hashable, Sendable, Codable {
  public var stopReason: StopReason
  public var usage: Usage?

  public init(stopReason: StopReason = .stop, usage: Usage? = nil) {
    self.stopReason = stopReason
    self.usage = usage
  }

  public enum CodingKeys: String, CodingKey {
    case stopReason = "stop_reason"
    case usage = "usage"
  }
}

public enum AssistantMessagePhase: String, Hashable, Sendable, Codable {
  case commentary
  case finalAnswer = "final_answer"
}

public struct ToolResultMessage: Hashable, Sendable, Codable {
  public var toolCallId: String
  public var content: [ContentBlock]
  public var isError: Bool

  public init(
    toolCallId: String,
    content: [ContentBlock],
    isError: Bool = false,
  ) {
    self.toolCallId = toolCallId
    self.content = content
    self.isError = isError
  }

  public enum CodingKeys: String, CodingKey {
    case toolCallId = "tool_call_id"
    case content = "content"
    case isError = "is_error"
  }
}

public enum StopReason: String, Hashable, Sendable, Codable {
  case stop
  case maxTokens = "max_tokens"
  case refusal
}

public struct Usage: Hashable, Sendable, Codable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheReadTokens: Int
  public var cacheWriteTokens: Int
  public var reasoningTokens: Int
  public var totalTokens: Int

  public init(
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int = 0,
    cacheWriteTokens: Int = 0,
    reasoningTokens: Int = 0,
    totalTokens: Int,
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.reasoningTokens = reasoningTokens
    self.totalTokens = totalTokens
  }

  public enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case cacheWriteTokens = "cache_write_tokens"
    case reasoningTokens = "reasoning_tokens"
    case totalTokens = "total_tokens"
  }
}

// MARK: - Context & Options

public struct Context: Hashable, Sendable {
  public var systemPrompt: String?
  public var messages: [Message]
  public var tools: [Tool]?

  public init(
    systemPrompt: String? = nil,
    messages: [Message],
    tools: [Tool]? = nil,
  ) {
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }
}

public enum Tool: Hashable, Sendable, Codable {
  case function(name: String, description: String, parameters: JSONValue)
  case hosted(type: String)

  public init(name: String, description: String, parameters: JSONValue) {
    self = .function(name: name, description: description, parameters: parameters)
  }

  enum CodingKeys: String, CodingKey {
    case type
    case name
    case description
    case parameters
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let type = try container.decodeIfPresent(String.self, forKey: .type) {
      self = .hosted(type: type)
    } else {
      self = try .function(
        name: container.decode(String.self, forKey: .name),
        description: container.decode(String.self, forKey: .description),
        parameters: container.decode(JSONValue.self, forKey: .parameters),
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .function(name, description, parameters):
      try container.encode(name, forKey: .name)
      try container.encode(description, forKey: .description)
      try container.encode(parameters, forKey: .parameters)
    case let .hosted(type):
      try container.encode(type, forKey: .type)
    }
  }
}

public struct RequestOptions: Hashable, Sendable {
  public var temperature: Double?
  public var maxTokens: Int?
  public var reasoning: ReasoningOptions
  public var toolChoice: ToolChoice
  public var idleTimeout: Duration?

  public init(
    temperature: Double? = nil,
    maxTokens: Int? = nil,
    reasoning: ReasoningOptions = .automatic,
    toolChoice: ToolChoice = .none,
    idleTimeout: Duration? = nil,
  ) {
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.reasoning = reasoning
    self.toolChoice = toolChoice
    self.idleTimeout = idleTimeout
  }
}

public enum ReasoningOptions: Hashable, Sendable {
  case none
  case automatic
  case effort(String)
  case budget(Int)
}

public enum ToolChoice: Hashable, Sendable {
  case none
  case any
  case tool(name: String)
}

public enum ResponseVerbosity: String, Hashable, Sendable {
  case low
  case medium
  case high
}

public enum CacheRetention: Hashable, Sendable {
  case short
  case long
}

// MARK: - SSEEvent (self-contained, no external dependency)

/// An SSE (Server-Sent Events) event.
public struct SSEEvent: Sendable, Equatable {
  public var event: String
  public var data: String
  public var id: String?
  public var retry: Int?

  public init(
    event: String = "message",
    data: String,
    id: String? = nil,
    retry: Int? = nil,
  ) {
    self.event = event
    self.data = data
    self.id = id
    self.retry = retry
  }
}

extension Substring {
  var trimmedWhitespace: Substring {
    var raw = self
    while raw.first?.isWhitespace == true { raw.removeFirst() }
    while raw.last?.isWhitespace == true { raw.removeLast() }
    return raw
  }
}
