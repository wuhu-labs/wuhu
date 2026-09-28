#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct CredentialsFile: Sendable, Hashable, Codable {
  public var version: Int
  public var providers: [String: StoredCredential]

  public init(version: Int = 1, providers: [String: StoredCredential] = [:]) {
    self.version = version
    self.providers = providers
  }

  public static let empty: CredentialsFile = CredentialsFile()
}

public enum StoredCredential: Sendable, Hashable {
  case apiKey(String)
  case chatGPTOAuth(ChatGPTTokens)
  case claudeCodeOAuth(String)
}

public struct ChatGPTTokens: Sendable, Hashable, Codable {
  public var idToken: String?
  public var accessToken: String
  public var refreshToken: String
  public var accountID: String
  public var expiresAt: Date

  public init(
    idToken: String?,
    accessToken: String,
    refreshToken: String,
    accountID: String,
    expiresAt: Date,
  ) {
    self.idToken = idToken
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.accountID = accountID
    self.expiresAt = expiresAt
  }

  public func needsRefresh(at now: Date, window: TimeInterval = 300) -> Bool {
    expiresAt.timeIntervalSince(now) < window
  }
}

extension StoredCredential: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case apiKey
    case claudeCodeOAuthToken
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "apiKey":
      self = .apiKey(try container.decode(String.self, forKey: .apiKey))
    case "claudeCodeOAuth":
      self = .claudeCodeOAuth(try container.decode(String.self, forKey: .claudeCodeOAuthToken))
    case "chatgptOAuth":
      self = .chatGPTOAuth(try ChatGPTTokens(from: decoder))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "unknown credential kind \(kind)",
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .apiKey(key):
      try container.encode("apiKey", forKey: .kind)
      try container.encode(key, forKey: .apiKey)
    case let .claudeCodeOAuth(token):
      try container.encode("claudeCodeOAuth", forKey: .kind)
      try container.encode(token, forKey: .claudeCodeOAuthToken)
    case let .chatGPTOAuth(tokens):
      try container.encode("chatgptOAuth", forKey: .kind)
      try tokens.encode(to: encoder)
    }
  }
}
