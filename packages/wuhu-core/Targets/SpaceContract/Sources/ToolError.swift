import Contract
import JSONValue

@Contract
public enum ErrorCode: String, Codable, Equatable, Sendable {
  case notFound
  case conflict
  case invalidPath
  case invalidArgument
  case unauthorized
  case unsupported
  case unavailable
  case `internal`
}

@Contract
public struct ToolError: Codable, Equatable, Sendable {
  public let code: ErrorCode
  public let message: String
  public let hint: String?
  /// A conflict's current version token, when the verb reports one.
  public let token: String?
}
