import Contract
import JSONValue

@Contract
public struct EnrollMintInput: Codable, Equatable, Sendable {
  public let account: String
  public let capabilities: [String]
  public let ttlSeconds: Int?
}

@Contract
public struct EnrollMintOutput: Codable, Equatable, Sendable {
  public let token: String
  public let expiresAt: Double
  public let space: String
  public let fingerprint: String?
}

@Contract
public struct EnrollConsumeInput: Codable, Equatable, Sendable {
  public let token: String
  public let pubkey: String
  public let name: String?
}

@Contract
public struct EnrollConsumeOutput: Codable, Equatable, Sendable {
  public let account: String
  public let capabilities: [String]
  public let machine: String?
  public let machineName: String?
}

@Contract
public struct EnrollRevokeInput: Codable, Equatable, Sendable {
  public let token: String
}

@Contract
public struct ShareLoginChallengeOutput: Codable, Equatable, Sendable {
  public let challenge: String
}

@Contract
public struct PersonaMintOutput: Codable, Equatable, Sendable {
  public let persona: String
}

@Contract
public struct ShareLoginInput: Codable, Equatable, Sendable {
  public let pubkey: String
  public let challenge: String
  public let signature: String
  public let ttlSeconds: Int?
}

public enum ShareLogin {
  // Domain separation: a share-login signature must never verify as any other
  // signed statement, so the message carries its own context label.
  public static func signingMessage(challenge: String) -> String {
    "wuhu-share-login:\(challenge)"
  }

  public static let defaultTTLSeconds: Int = 600
  public static let maximumTTLSeconds: Int = 259_200
}

public enum EnrollLink {
  public static func format(origin: String, token: String, space: String, fingerprint: String?) -> String {
    origin + "/_/enroll#token=\(token)&space=\(space)" + (fingerprint.map { "&fp=\($0)" } ?? "")
  }
}

@Contract
public struct ShareLoginOutput: Codable, Equatable, Sendable {
  public let token: String
  public let expiresAt: Double
  public let space: String
  public let fingerprint: String?
}

@Contract
public struct AccountCreateInput: Codable, Equatable, Sendable {
  public let name: String?
  public let admin: Bool?
}

@Contract
public struct AccountPayload: Codable, Equatable, Sendable {
  public let id: String
  public let kind: String
  public let name: String?
  public let admin: Bool
  public let createdAt: Double
}

@Contract
public struct AccountListOutput: Codable, Equatable, Sendable {
  public let accounts: [AccountPayload]
}

@Contract
public struct AccountRemoveOutput: Codable, Equatable, Sendable {
  public let keys: Int
  public let readSessions: Int
}

@Contract
public struct AccountAdminInput: Codable, Equatable, Sendable {
  public let admin: Bool
}

@Contract
public struct KeyPayload: Codable, Equatable, Sendable {
  public let pubkey: String
  public let account: String
  public let capabilities: [String]
  public let createdBy: String?
  public let createdAt: Double
  public let expiresAt: Double?
}

@Contract
public struct KeyListOutput: Codable, Equatable, Sendable {
  public let keys: [KeyPayload]
}

@Contract
public struct KeyRevokeInput: Codable, Equatable, Sendable {
  public let pubkey: String
}
