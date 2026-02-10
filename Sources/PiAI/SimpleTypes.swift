import Foundation

public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(_ value: Any?) throws {
    switch value {
    case nil:
      self = .null
    case let v as NSNull:
      _ = v
      self = .null
    case let v as Bool:
      self = .bool(v)
    case let v as Int:
      self = .number(Double(v))
    case let v as Double:
      self = .number(v)
    case let v as Float:
      self = .number(Double(v))
    case let v as String:
      self = .string(v)
    case let v as [Any]:
      self = try .array(v.map { try JSONValue($0) })
    case let v as [String: Any]:
      var obj: [String: JSONValue] = [:]
      obj.reserveCapacity(v.count)
      for (k, vv) in v {
        obj[k] = try JSONValue(vv)
      }
      self = .object(obj)
    default:
      throw PiAIError.decoding("Unsupported JSON value type: \(type(of: value as Any))")
    }
  }

  public func toAny() -> Any {
    switch self {
    case .null:
      return NSNull()
    case let .bool(v):
      return v
    case let .number(v):
      return v
    case let .string(v):
      return v
    case let .array(v):
      return v.map { $0.toAny() }
    case let .object(v):
      var obj: [String: Any] = [:]
      obj.reserveCapacity(v.count)
      for (k, vv) in v {
        obj[k] = vv.toAny()
      }
      return obj
    }
  }

  public var asObject: [String: JSONValue]? {
    if case let .object(v) = self { return v }
    return nil
  }

  public var asString: String? {
    if case let .string(v) = self { return v }
    return nil
  }
}

public struct Tool: Sendable, Hashable {
  public var name: String
  public var description: String
  /// JSON Schema (subset) describing tool parameters.
  public var parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public struct ToolCall: Sendable, Hashable {
  public var id: String
  public var name: String
  public var arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct UserMessage: Sendable, Hashable {
  public var content: String
  public var timestamp: Date

  public init(content: String, timestamp: Date = Date()) {
    self.content = content
    self.timestamp = timestamp
  }
}

public struct ToolResultMessage: Sendable, Hashable {
  public var toolCallId: String
  public var toolName: String
  public var content: String
  public var isError: Bool
  public var timestamp: Date

  public init(
    toolCallId: String,
    toolName: String,
    content: String,
    isError: Bool,
    timestamp: Date = Date(),
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.content = content
    self.isError = isError
    self.timestamp = timestamp
  }
}

public enum Message: Sendable, Hashable {
  case user(UserMessage)
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)
}

public struct SimpleContext: Sendable, Hashable {
  public var systemPrompt: String?
  public var messages: [Message]
  public var tools: [Tool]?

  public init(systemPrompt: String? = nil, messages: [Message], tools: [Tool]? = nil) {
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }
}

public func validateToolArguments(tool: Tool, toolCall: ToolCall) throws -> JSONValue {
  try validateToolArguments(tool: tool, arguments: toolCall.arguments)
}

public func validateToolArguments(tool: Tool, arguments: JSONValue) throws -> JSONValue {
  guard let schemaObj = tool.parameters.asObject else {
    throw PiAIError.decoding("Tool parameters schema must be an object")
  }
  let schemaType = schemaObj["type"]?.asString
  guard schemaType == "object" else {
    throw PiAIError.unsupported("Only JSON Schema type=object is supported for tool parameters")
  }

  guard let argsObj = arguments.asObject else {
    throw PiAIError.decoding("Tool arguments must be an object")
  }

  let requiredKeys: [String] = {
    guard case let .array(arr)? = schemaObj["required"] else { return [] }
    return arr.compactMap(\.asString)
  }()

  for key in requiredKeys {
    guard argsObj[key] != nil else {
      throw PiAIError.decoding("Missing required tool argument: \(key)")
    }
  }

  if case let .object(props)? = schemaObj["properties"] {
    for (key, propSchema) in props {
      guard let value = argsObj[key] else { continue }
      try validateSchema(propSchema, value: value, path: key)
    }
  }

  return .object(argsObj)
}

private func validateSchema(_ schema: JSONValue, value: JSONValue, path: String) throws {
  guard let obj = schema.asObject else { return }
  let type = obj["type"]?.asString
  switch type {
  case "string":
    guard case .string = value else { throw PiAIError.decoding("Expected string at \(path)") }
  case "number":
    guard case .number = value else { throw PiAIError.decoding("Expected number at \(path)") }
  case "boolean":
    guard case .bool = value else { throw PiAIError.decoding("Expected boolean at \(path)") }
  case "object":
    guard case .object = value else { throw PiAIError.decoding("Expected object at \(path)") }
  case "array":
    guard case .array = value else { throw PiAIError.decoding("Expected array at \(path)") }
  case nil:
    return
  default:
    throw PiAIError.unsupported("Unsupported schema type \(String(describing: type)) at \(path)")
  }
}
