import Dependencies
import Foundation
import SpaceIDs
import struct SpaceIDs.AccountID
import TenancyContract

public struct ReadSessionToken: Hashable, Sendable {
  static let prefix: String = "rs_"
  static let suffixLength: Int = 32

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

public enum AccountKind: String, Hashable, Sendable, CaseIterable {
  case human
  case space
}

public struct AccountRecord: Equatable, Sendable {
  public let id: AccountID
  public let kind: AccountKind
  public let name: String?
  /// A person admitted to listed groups only: no open-group reach, no sessions.
  public let guest: Bool
  public let createdAt: Date
  public let removedAt: Date?
}

func randomAlphanumericSuffix(_ count: Int, rng: WithRandomNumberGenerator) -> String {
  rng { generator in randomAlphanumericSuffix(count, using: &generator) }
}

extension Space {
  func randomSuffix(_ count: Int) -> String {
    rng { randomAlphanumericSuffix(count, using: &$0) }
  }
}
