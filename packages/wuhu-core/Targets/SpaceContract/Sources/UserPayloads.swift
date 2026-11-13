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

@Contract
public struct HiddenSidebarAddress: Codable, Equatable, Hashable, Sendable {
  public let group: String
  public let path: String
}

@Contract
public struct UserSettingsPayload: Codable, Equatable, Sendable {
  public let hidden: [HiddenSidebarAddress]
}

@Contract
public struct SidebarVisibilityInput: Codable, Equatable, Sendable {
  public let group: String
  public let path: String
  public let hidden: Bool
}
