import Dependencies
import Foundation

public struct AccountID: Hashable, Sendable {
  static let prefix: String = "ac_"
  static let suffixLength: Int = 8

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

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
  case machine
}

public enum KeyCapability: String, Hashable, Sendable, CaseIterable {
  case device
  case seat
  case execMachine = "exec-machine"
  case space
}

public struct AccountRecord: Equatable, Sendable {
  public let id: AccountID
  public let kind: AccountKind
  public let name: String?
  public let isAdmin: Bool
  /// A person admitted to listed groups only: no open-group reach, no sessions.
  public let guest: Bool
  public let createdAt: Date
  public let removedAt: Date?
}

public struct KeyRecord: Equatable, Sendable {
  public let pubkey: String
  public let account: AccountID
  public let capabilities: Set<KeyCapability>
  public let createdBy: AccountID?
  public let createdAt: Date
  public let expiresAt: Date?
}

func hasPrefixedAlphanumericSuffix(_ candidate: String, prefix: String, count: Int) -> Bool {
  guard candidate.hasPrefix(prefix) else { return false }
  let suffix = candidate.dropFirst(prefix.count)
  guard suffix.count == count else { return false }
  return suffix.allSatisfy { $0.isASCII && (("a" ... "z").contains($0) || ("0" ... "9").contains($0)) }
}

private let alphanumericAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

func randomAlphanumericSuffix(_ count: Int, rng: WithRandomNumberGenerator) -> String {
  rng { generator in randomAlphanumericSuffix(count, using: &generator) }
}

func randomAlphanumericSuffix(_ count: Int, using generator: inout some RandomNumberGenerator) -> String {
  String((0 ..< count).map { _ in alphanumericAlphabet.randomElement(using: &generator)! })
}
