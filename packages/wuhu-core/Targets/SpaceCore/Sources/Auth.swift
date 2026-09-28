import Dependencies
import Foundation

let authSchemaSQL = """
CREATE TABLE IF NOT EXISTS "accounts" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "kind" TEXT NOT NULL CHECK ("kind" IN ('human', 'space', 'machine', 'contractor')),
  "name" TEXT,
  "created_at" TEXT NOT NULL,
  "removed_at" TEXT
);
CREATE TABLE IF NOT EXISTS "account_keys" (
  "pubkey" TEXT NOT NULL PRIMARY KEY,
  "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
  "capabilities" TEXT NOT NULL,
  "created_by" TEXT REFERENCES "accounts" ("id"),
  "created_at" TEXT NOT NULL,
  "expires_at" TEXT
);
CREATE INDEX IF NOT EXISTS "account_keys_by_account" ON "account_keys" ("account_id");
CREATE TABLE IF NOT EXISTS "read_sessions" (
  "token_hash" TEXT NOT NULL PRIMARY KEY,
  "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
  "created_at" TEXT NOT NULL,
  "expires_at" TEXT NOT NULL,
  "grp" TEXT
);
CREATE INDEX IF NOT EXISTS "read_sessions_by_account" ON "read_sessions" ("account_id");
"""

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

// `contractor` decodes the accounts and keys of the removed contractor
// executor in an old space; nothing creates one and its keys are refused.
public enum AccountKind: String, Hashable, Sendable, CaseIterable {
  case human
  case space
  case machine
  case contractor
}

public enum KeyCapability: String, Hashable, Sendable, CaseIterable {
  case device
  case seat
  case contractor
  case execMachine = "exec-machine"
  case space
}

public struct AccountRecord: Equatable, Sendable {
  public let id: AccountID
  public let kind: AccountKind
  public let name: String?
  public let isAdmin: Bool
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
