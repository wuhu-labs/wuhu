import Foundation
import PiAI

public enum WuhuRunnerMessage: Sendable, Hashable, Codable {
  case hello(runnerName: String, version: Int)

  case resolveEnvironmentRequest(id: String, sessionID: String?, name: String)
  case resolveEnvironmentResponse(id: String, environment: WuhuEnvironment?, error: String?)

  case registerSession(sessionID: String, environment: WuhuEnvironment)

  case toolRequest(id: String, sessionID: String, toolCallId: String, toolName: String, args: JSONValue)
  case toolResponse(id: String, sessionID: String, toolCallId: String, result: WuhuToolResult?, isError: Bool, errorMessage: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case id
    case runnerName
    case version
    case name
    case environment
    case error
    case sessionID
    case toolCallId
    case toolName
    case args
    case result
    case isError
    case errorMessage
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "hello":
      self = try .hello(
        runnerName: c.decode(String.self, forKey: .runnerName),
        version: c.decode(Int.self, forKey: .version),
      )

    case "resolve_environment_request":
      self = try .resolveEnvironmentRequest(
        id: c.decode(String.self, forKey: .id),
        sessionID: c.decodeIfPresent(String.self, forKey: .sessionID),
        name: c.decode(String.self, forKey: .name),
      )

    case "resolve_environment_response":
      self = try .resolveEnvironmentResponse(
        id: c.decode(String.self, forKey: .id),
        environment: c.decodeIfPresent(WuhuEnvironment.self, forKey: .environment),
        error: c.decodeIfPresent(String.self, forKey: .error),
      )

    case "register_session":
      self = try .registerSession(
        sessionID: c.decode(String.self, forKey: .sessionID),
        environment: c.decode(WuhuEnvironment.self, forKey: .environment),
      )

    case "tool_request":
      self = try .toolRequest(
        id: c.decode(String.self, forKey: .id),
        sessionID: c.decode(String.self, forKey: .sessionID),
        toolCallId: c.decode(String.self, forKey: .toolCallId),
        toolName: c.decode(String.self, forKey: .toolName),
        args: c.decode(JSONValue.self, forKey: .args),
      )

    case "tool_response":
      self = try .toolResponse(
        id: c.decode(String.self, forKey: .id),
        sessionID: c.decode(String.self, forKey: .sessionID),
        toolCallId: c.decode(String.self, forKey: .toolCallId),
        result: c.decodeIfPresent(WuhuToolResult.self, forKey: .result),
        isError: c.decode(Bool.self, forKey: .isError),
        errorMessage: c.decodeIfPresent(String.self, forKey: .errorMessage),
      )

    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown runner message type: \\(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .hello(runnerName, version):
      try c.encode("hello", forKey: .type)
      try c.encode(runnerName, forKey: .runnerName)
      try c.encode(version, forKey: .version)

    case let .resolveEnvironmentRequest(id, sessionID, name):
      try c.encode("resolve_environment_request", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(sessionID, forKey: .sessionID)
      try c.encode(name, forKey: .name)

    case let .resolveEnvironmentResponse(id, environment, error):
      try c.encode("resolve_environment_response", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(environment, forKey: .environment)
      try c.encodeIfPresent(error, forKey: .error)

    case let .registerSession(sessionID, environment):
      try c.encode("register_session", forKey: .type)
      try c.encode(sessionID, forKey: .sessionID)
      try c.encode(environment, forKey: .environment)

    case let .toolRequest(id, sessionID, toolCallId, toolName, args):
      try c.encode("tool_request", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(sessionID, forKey: .sessionID)
      try c.encode(toolCallId, forKey: .toolCallId)
      try c.encode(toolName, forKey: .toolName)
      try c.encode(args, forKey: .args)

    case let .toolResponse(id, sessionID, toolCallId, result, isError, errorMessage):
      try c.encode("tool_response", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(sessionID, forKey: .sessionID)
      try c.encode(toolCallId, forKey: .toolCallId)
      try c.encodeIfPresent(result, forKey: .result)
      try c.encode(isError, forKey: .isError)
      try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
  }
}
