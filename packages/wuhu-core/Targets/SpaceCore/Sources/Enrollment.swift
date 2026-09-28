import Foundation
import GRDB
import struct SpaceContract.GroupID

let enrollmentSchemaSQL = """
CREATE TABLE IF NOT EXISTS "join_tokens" (
  "token_hash" TEXT NOT NULL PRIMARY KEY,
  "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
  "capabilities" TEXT NOT NULL,
  "created_by" TEXT REFERENCES "accounts" ("id"),
  "created_at" TEXT NOT NULL,
  "expires_at" TEXT NOT NULL,
  "grp" TEXT NOT NULL DEFAULT ''
);
CREATE TRIGGER IF NOT EXISTS "join_tokens_grp_required" BEFORE INSERT ON "join_tokens" WHEN NEW."grp" = ''
  BEGIN SELECT RAISE(ABORT, 'grp required: join_tokens'); END;
CREATE INDEX IF NOT EXISTS "join_tokens_by_account" ON "join_tokens" ("account_id");
"""

public struct JoinToken: Hashable, Sendable {
  static let prefix: String = "jt_"
  static let suffixLength: Int = 32

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

public struct JoinTokenRejected: Error, Equatable, Sendable {}

public struct MintedJoinToken: Equatable, Sendable {
  public let token: JoinToken
  public let expiresAt: Date
}

extension Space {
  public func mintJoinToken(
    account: AccountID,
    capabilities: Set<KeyCapability>,
    createdBy: AccountID?,
    lifetime: TimeInterval,
  ) async throws -> MintedJoinToken {
    precondition(!capabilities.isEmpty, "a join token needs at least one capability")
    precondition(lifetime > 0, "a join token needs a positive lifetime")
    let token = JoinToken(rawValue: JoinToken.prefix + randomSuffix(JoinToken.suffixLength))
    let createdAt = dateGen.now
    let expiresAt = createdAt.addingTimeInterval(lifetime)
    try await writer.write { db in
      try Self.requireAccount(account, in: db)
      try db.execute(
        sql: "INSERT INTO join_tokens (token_hash, account_id, capabilities, created_by, created_at, expires_at, grp) VALUES (?, ?, ?, ?, ?, ?, ?)",
        arguments: [
          Self.credentialDigest(token.rawValue),
          account.rawValue,
          Self.stored(capabilities),
          createdBy?.rawValue,
          SQLiteDateFormat.string(from: createdAt),
          SQLiteDateFormat.string(from: expiresAt),
          GroupID.shared.rawValue,
        ],
      )
    }
    return MintedJoinToken(token: token, expiresAt: expiresAt)
  }

  // One serialized write transaction claims the token row and enrolls the key,
  // so two racing consumers cannot both succeed; any throw rolls both back.
  public func consumeJoinToken(_ token: JoinToken, pubkey: String) async throws -> KeyRecord {
    guard JoinToken.isValid(token.rawValue) else { throw JoinTokenRejected() }
    let now = dateGen.now
    let hash = Self.credentialDigest(token.rawValue)
    return try await writer.write { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM join_tokens WHERE token_hash = ?", arguments: [hash]) else {
        throw JoinTokenRejected()
      }
      try db.execute(sql: "DELETE FROM join_tokens WHERE token_hash = ?", arguments: [hash])
      guard try Self.isLive(SQLiteDateFormat.date(from: row["expires_at"]), at: now) else {
        throw JoinTokenRejected()
      }
      guard let capabilities = Self.capabilitySet(row["capabilities"]) else {
        throw CorruptCredentialRow(stored: row["capabilities"])
      }
      return try Self.insertKey(
        pubkey,
        account: AccountID(rawValue: row["account_id"]),
        capabilities: capabilities,
        createdBy: (row["created_by"] as String?).map(AccountID.init(rawValue:)),
        createdAt: now,
        expiresAt: nil,
        in: db,
      )
    }
  }

  // The gate runs inside the claiming transaction, so a refused revoke leaves
  // the invite alive instead of burning it on the way to the refusal.
  public func revokeJoinToken(
    _ token: JoinToken,
    revocableBy allows: @escaping @Sendable (AccountID) -> Bool,
  ) async throws -> AccountID? {
    guard JoinToken.isValid(token.rawValue) else { return nil }
    let now = dateGen.now
    let hash = Self.credentialDigest(token.rawValue)
    return try await writer.write { db in
      guard let row = try Row.fetchOne(
        db,
        sql: "SELECT account_id, expires_at FROM join_tokens WHERE token_hash = ?",
        arguments: [hash],
      ), try Self.isLive(SQLiteDateFormat.date(from: row["expires_at"]), at: now) else {
        return nil
      }
      let account = AccountID(rawValue: row["account_id"])
      guard allows(account) else { throw JoinTokenRevocationRefused(account: account) }
      try db.execute(sql: "DELETE FROM join_tokens WHERE token_hash = ?", arguments: [hash])
      return account
    }
  }
}

public struct JoinTokenRevocationRefused: Error, Equatable, Sendable {
  public let account: AccountID
}
