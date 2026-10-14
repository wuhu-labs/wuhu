#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct MachineContract.MachineID
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

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
  public func addMachineV2(name: String, group: GroupID = .shared) async throws -> (machine: MachineRecord, token: MintedJoinToken) {
    guard let name = MachineName.normalized(name), name.hasSuffix("-v2") else { throw SpaceError.invalidMachineName(name) }
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let account = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let token = JoinToken(rawValue: JoinToken.prefix + randomSuffix(JoinToken.suffixLength))
    let createdAt = dateGen.now
    let expiresAt = createdAt.addingTimeInterval(3600)
    let stamp = SQLiteDateFormat.string(from: createdAt)
    try await writer.write { db in
      try Self.requireMachineNameFree(name, besides: nil, in: db)
      try EnrollmentMachineAccountRow.insert {
        EnrollmentMachineAccountRow(id: account.rawValue, kind: AccountKind.machine.rawValue, name: name, createdAt: stamp, removedAt: nil)
      }.execute(db)
      try MachineRow.insert { MachineRow(id: id.rawValue, accountID: account.rawValue, name: name, createdAt: stamp, grp: group.rawValue) }.execute(db)
      try MachineV2MemberRow.insert { MachineV2MemberRow(machineID: id.rawValue, grp: group.rawValue, createdAt: stamp) }.execute(db)
      try EnrollmentTokenRow.insert {
        EnrollmentTokenRow(tokenHash: Self.credentialDigest(token.rawValue), accountID: account.rawValue, capabilities: Self.stored([.execMachine]), createdBy: nil, createdAt: stamp, expiresAt: SQLiteDateFormat.string(from: expiresAt), grp: GroupID.shared.rawValue)
      }.execute(db)
    }
    return (MachineRecord(id: id, account: account, name: name, createdAt: createdAt, group: group), MintedJoinToken(token: token, expiresAt: expiresAt))
  }

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
      try EnrollmentTokenRow.insert {
        EnrollmentTokenRow(tokenHash: Self.credentialDigest(token.rawValue), accountID: account.rawValue, capabilities: Self.stored(capabilities), createdBy: createdBy?.rawValue, createdAt: SQLiteDateFormat.string(from: createdAt), expiresAt: SQLiteDateFormat.string(from: expiresAt), grp: GroupID.shared.rawValue)
      }.execute(db)
    }
    return MintedJoinToken(token: token, expiresAt: expiresAt)
  }

  // One serialized write transaction claims the token row and enrolls the key,
  // so two racing consumers cannot both succeed; any throw rolls both back.
  public func consumeJoinToken(_ token: JoinToken, pubkey: String) async throws -> KeyRecord {
    try await consumeJoinToken(token, pubkey: pubkey, machineV2: false)
  }

  public func consumeMachineV2JoinToken(_ token: JoinToken, pubkey: String) async throws -> KeyRecord {
    try await consumeJoinToken(token, pubkey: pubkey, machineV2: true)
  }

  private func consumeJoinToken(_ token: JoinToken, pubkey: String, machineV2: Bool) async throws -> KeyRecord {
    guard JoinToken.isValid(token.rawValue) else { throw JoinTokenRejected() }
    let now = dateGen.now
    let hash = Self.credentialDigest(token.rawValue)
    return try await writer.write { db in
      guard let row = try EnrollmentTokenRow.where({ $0.tokenHash.eq(hash) }).fetchOne(db) else {
        throw JoinTokenRejected()
      }
      if machineV2 {
        guard let machine = try MachineRow.where({ $0.accountID.eq(row.accountID) }).fetchOne(db),
              try MachineV2MemberRow.where({ $0.machineID.eq(machine.id) && $0.grp.eq(machine.grp) }).fetchOne(db) != nil else { throw JoinTokenRejected() }
      }
      guard try Self.isLive(SQLiteDateFormat.date(from: row.expiresAt), at: now) else {
        throw JoinTokenRejected()
      }
      guard let capabilities = Self.capabilitySet(row.capabilities) else {
        throw CorruptCredentialRow(stored: row.capabilities)
      }
      try EnrollmentTokenRow.where { $0.tokenHash.eq(hash) }.delete().execute(db)
      return try Self.insertKey(
        pubkey,
        account: AccountID(rawValue: row.accountID),
        capabilities: capabilities,
        createdBy: row.createdBy.map(AccountID.init(rawValue:)),
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
      guard let row = try EnrollmentTokenRow.where({ $0.tokenHash.eq(hash) }).fetchOne(db),
            try Self.isLive(SQLiteDateFormat.date(from: row.expiresAt), at: now)
      else {
        return nil
      }
      let account = AccountID(rawValue: row.accountID)
      guard allows(account) else { throw JoinTokenRevocationRefused(account: account) }
      try EnrollmentTokenRow.where { $0.tokenHash.eq(hash) }.delete().execute(db)
      return account
    }
  }
}

public struct JoinTokenRevocationRefused: Error, Equatable, Sendable {
  public let account: AccountID
}

@Table("join_tokens")
private struct EnrollmentTokenRow {
  @Column("token_hash", primaryKey: true) var tokenHash: String
  @Column("account_id") var accountID: String
  var capabilities: String
  @Column("created_by") var createdBy: String?
  @Column("created_at") var createdAt: String
  @Column("expires_at") var expiresAt: String
  var grp: String
}

@Table("accounts")
private struct EnrollmentMachineAccountRow {
  @Column("id", primaryKey: true) var id: String
  var kind: String
  var name: String?
  @Column("created_at") var createdAt: String
  @Column("removed_at") var removedAt: String?
}
