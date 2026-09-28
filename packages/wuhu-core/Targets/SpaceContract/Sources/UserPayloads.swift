import Contract
import JSONValue

@Contract
public struct UserPayload: Codable, Equatable, Sendable {
  public let id: String
  public let handle: String?
  public let displayName: String?
}

@Contract
public struct UsersOutput: Codable, Equatable, Sendable {
  public let users: [UserPayload]
}

@Contract
public struct UserProfileInput: Codable, Equatable, Sendable {
  public let handle: String
  public let displayName: String?
}
