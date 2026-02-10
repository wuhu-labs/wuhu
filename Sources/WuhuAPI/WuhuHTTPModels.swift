import Foundation
import PiAI

public struct WuhuCreateSessionRequest: Sendable, Hashable, Codable {
  public var provider: WuhuProvider
  public var model: String?
  public var systemPrompt: String?
  public var environment: String
  public var runner: String?
  public var parentSessionID: String?

  public init(
    provider: WuhuProvider,
    model: String? = nil,
    systemPrompt: String? = nil,
    environment: String,
    runner: String? = nil,
    parentSessionID: String? = nil,
  ) {
    self.provider = provider
    self.model = model
    self.systemPrompt = systemPrompt
    self.environment = environment
    self.runner = runner
    self.parentSessionID = parentSessionID
  }
}

public struct WuhuPromptRequest: Sendable, Hashable, Codable {
  public var input: String
  public var maxTurns: Int?

  public init(input: String, maxTurns: Int? = nil) {
    self.input = input
    self.maxTurns = maxTurns
  }
}

public struct WuhuGetSessionResponse: Sendable, Hashable, Codable {
  public var session: WuhuSession
  public var transcript: [WuhuSessionEntry]

  public init(session: WuhuSession, transcript: [WuhuSessionEntry]) {
    self.session = session
    self.transcript = transcript
  }
}

public struct WuhuToolResult: Sendable, Hashable, Codable {
  public var content: [WuhuContentBlock]
  public var details: JSONValue

  public init(content: [WuhuContentBlock], details: JSONValue) {
    self.content = content
    self.details = details
  }
}

public enum WuhuPromptEvent: Sendable, Hashable, Codable {
  case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
  case toolExecutionEnd(toolCallId: String, toolName: String, result: WuhuToolResult, isError: Bool)
  case assistantTextDelta(String)
  case done

  enum CodingKeys: String, CodingKey {
    case type
    case toolCallId
    case toolName
    case args
    case result
    case isError
    case delta
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "tool_execution_start":
      self = try .toolExecutionStart(
        toolCallId: c.decode(String.self, forKey: .toolCallId),
        toolName: c.decode(String.self, forKey: .toolName),
        args: c.decode(JSONValue.self, forKey: .args),
      )
    case "tool_execution_end":
      self = try .toolExecutionEnd(
        toolCallId: c.decode(String.self, forKey: .toolCallId),
        toolName: c.decode(String.self, forKey: .toolName),
        result: c.decode(WuhuToolResult.self, forKey: .result),
        isError: c.decode(Bool.self, forKey: .isError),
      )
    case "assistant_text_delta":
      self = try .assistantTextDelta(c.decode(String.self, forKey: .delta))
    case "done":
      self = .done
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown prompt event type: \\(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .toolExecutionStart(toolCallId, toolName, args):
      try c.encode("tool_execution_start", forKey: .type)
      try c.encode(toolCallId, forKey: .toolCallId)
      try c.encode(toolName, forKey: .toolName)
      try c.encode(args, forKey: .args)
    case let .toolExecutionEnd(toolCallId, toolName, result, isError):
      try c.encode("tool_execution_end", forKey: .type)
      try c.encode(toolCallId, forKey: .toolCallId)
      try c.encode(toolName, forKey: .toolName)
      try c.encode(result, forKey: .result)
      try c.encode(isError, forKey: .isError)
    case let .assistantTextDelta(delta):
      try c.encode("assistant_text_delta", forKey: .type)
      try c.encode(delta, forKey: .delta)
    case .done:
      try c.encode("done", forKey: .type)
    }
  }
}
