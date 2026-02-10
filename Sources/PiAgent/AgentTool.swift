import Foundation
import PiAI

public struct AgentToolResult: Sendable, Hashable {
  public var content: [ContentBlock]
  public var details: JSONValue

  public init(content: [ContentBlock], details: JSONValue = .object([:])) {
    self.content = content
    self.details = details
  }
}

public struct AnyAgentTool: Sendable {
  public var tool: Tool
  public var label: String

  private let _execute: @Sendable (String, JSONValue) async throws -> AgentToolResult

  public init(
    tool: Tool,
    label: String,
    execute: @escaping @Sendable (String, JSONValue) async throws -> AgentToolResult,
  ) {
    self.tool = tool
    self.label = label
    _execute = execute
  }

  public func execute(toolCallId: String, args: JSONValue) async throws -> AgentToolResult {
    try await _execute(toolCallId, args)
  }
}

public extension AnyAgentTool {
  init<Parameters: Decodable & Sendable>(
    name: String,
    label: String,
    description: String,
    parametersSchema: JSONValue,
    execute: @escaping @Sendable (String, Parameters) async throws -> AgentToolResult,
  ) {
    let tool = Tool(name: name, description: description, parameters: parametersSchema)
    self.init(tool: tool, label: label) { toolCallId, args in
      do {
        let params = try decode(Parameters.self, from: args)
        return try await execute(toolCallId, params)
      } catch let error as DecodingError {
        throw PiAIError.decoding(
          "Invalid arguments for tool '\(name)': \(describeDecodingError(error)). arguments=\(compactJSONString(args))",
        )
      }
    }
  }
}

private func decode<T: Decodable>(_: T.Type, from value: JSONValue) throws -> T {
  let data = try JSONSerialization.data(withJSONObject: value.toAny())
  return try JSONDecoder().decode(T.self, from: data)
}

private func describeDecodingError(_ error: DecodingError) -> String {
  switch error {
  case let .dataCorrupted(context):
    return "\(formatCodingPath(context.codingPath)): \(context.debugDescription)"
  case let .keyNotFound(key, context):
    return "\(formatCodingPath(context.codingPath + [key])): \(context.debugDescription)"
  case let .typeMismatch(type, context):
    return "\(formatCodingPath(context.codingPath)): expected \(type). \(context.debugDescription)"
  case let .valueNotFound(type, context):
    return "\(formatCodingPath(context.codingPath)): expected \(type). \(context.debugDescription)"
  @unknown default:
    return String(describing: error)
  }
}

private func formatCodingPath(_ path: [any CodingKey]) -> String {
  let parts = path.map { key in
    if let i = key.intValue { return "[\(i)]" }
    return key.stringValue
  }
  let joined = parts.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
  return joined.isEmpty ? "<root>" : joined
}

private func compactJSONString(_ value: JSONValue, maxBytes: Int = 2048) -> String {
  let any = value.toAny()
  guard JSONSerialization.isValidJSONObject(any),
        let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
        var text = String(data: data, encoding: .utf8)
  else {
    return String(describing: any)
  }

  if text.utf8.count > maxBytes {
    while text.utf8.count > maxBytes, !text.isEmpty {
      text.removeLast()
    }
    text += "…"
  }
  return text
}
