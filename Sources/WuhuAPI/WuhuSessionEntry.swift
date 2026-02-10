import Foundation
import PiAI

public struct WuhuSessionHeader: Sendable, Hashable, Codable {
  public var version: Int
  public var systemPrompt: String
  public var metadata: JSONValue

  public init(version: Int = 1, systemPrompt: String, metadata: JSONValue = .object([:])) {
    self.version = version
    self.systemPrompt = systemPrompt
    self.metadata = metadata
  }
}

public struct WuhuToolExecution: Sendable, Hashable, Codable {
  public enum Phase: String, Sendable, Hashable, Codable {
    case start
    case end
  }

  public var phase: Phase
  public var toolCallId: String
  public var toolName: String
  public var arguments: JSONValue
  public var result: JSONValue?
  public var isError: Bool?

  public init(
    phase: Phase,
    toolCallId: String,
    toolName: String,
    arguments: JSONValue,
    result: JSONValue? = nil,
    isError: Bool? = nil,
  ) {
    self.phase = phase
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.arguments = arguments
    self.result = result
    self.isError = isError
  }
}

public enum WuhuEntryPayload: Sendable, Hashable, Codable {
  case header(WuhuSessionHeader)
  case message(WuhuPersistedMessage)
  case toolExecution(WuhuToolExecution)
  case custom(customType: String, data: JSONValue?)
  case unknown(type: String, payload: JSONValue)

  enum CodingKeys: String, CodingKey {
    case type
    case payload
    case customType
    case data
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "header":
      self = try .header(c.decode(WuhuSessionHeader.self, forKey: .payload))
    case "message":
      self = try .message(c.decode(WuhuPersistedMessage.self, forKey: .payload))
    case "tool_execution":
      self = try .toolExecution(c.decode(WuhuToolExecution.self, forKey: .payload))
    case "custom":
      self = try .custom(customType: c.decode(String.self, forKey: .customType), data: c.decodeIfPresent(JSONValue.self, forKey: .data))
    default:
      self = try .unknown(type: type, payload: (c.decodeIfPresent(JSONValue.self, forKey: .payload)) ?? .null)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .header(h):
      try c.encode("header", forKey: .type)
      try c.encode(h, forKey: .payload)
    case let .message(m):
      try c.encode("message", forKey: .type)
      try c.encode(m, forKey: .payload)
    case let .toolExecution(t):
      try c.encode("tool_execution", forKey: .type)
      try c.encode(t, forKey: .payload)
    case let .custom(customType, data):
      try c.encode("custom", forKey: .type)
      try c.encode(customType, forKey: .customType)
      try c.encodeIfPresent(data, forKey: .data)
    case let .unknown(type, payload):
      try c.encode(type, forKey: .type)
      try c.encode(payload, forKey: .payload)
    }
  }

  public var typeString: String {
    switch self {
    case .header:
      "header"
    case .message:
      "message"
    case .toolExecution:
      "tool_execution"
    case .custom:
      "custom"
    case let .unknown(type, _):
      type
    }
  }
}

public struct WuhuSessionEntry: Sendable, Hashable, Codable, Identifiable {
  public var id: Int64
  public var sessionID: String
  public var parentEntryID: Int64?
  public var createdAt: Date
  public var payload: WuhuEntryPayload

  public init(
    id: Int64,
    sessionID: String,
    parentEntryID: Int64?,
    createdAt: Date,
    payload: WuhuEntryPayload,
  ) {
    self.id = id
    self.sessionID = sessionID
    self.parentEntryID = parentEntryID
    self.createdAt = createdAt
    self.payload = payload
  }
}
