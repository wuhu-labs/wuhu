import SpaceIDs
import struct SpaceIDs.AccountID
import func SpaceIDs.hasPrefixedAlphanumericSuffix

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum KeyCapability: String, Hashable, Sendable, CaseIterable {
  case device
  case seat
  case execMachine = "exec-machine"
  case space
}

public struct KeyRecord: Equatable, Sendable {
  public let pubkey: String
  public let account: AccountID
  public let capabilities: Set<KeyCapability>
  public let createdBy: AccountID?
  public let createdAt: Date
  public let expiresAt: Date?

  public init(pubkey: String, account: AccountID, capabilities: Set<KeyCapability>, createdBy: AccountID?, createdAt: Date, expiresAt: Date?) {
    self.pubkey = pubkey; self.account = account; self.capabilities = capabilities; self.createdBy = createdBy
    self.createdAt = createdAt; self.expiresAt = expiresAt
  }
}

public struct JoinToken: Hashable, Sendable {
  public static let prefix: String = "jt_"
  public static let suffixLength: Int = 32

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

public struct JoinTokenRejected: Error, Equatable, Sendable {
  public init() {}
}

public struct MintedJoinToken: Equatable, Sendable {
  public let token: JoinToken
  public let expiresAt: Date

  public init(token: JoinToken, expiresAt: Date) {
    self.token = token; self.expiresAt = expiresAt
  }
}
