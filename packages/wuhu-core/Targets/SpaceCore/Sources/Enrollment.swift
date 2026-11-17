import SpaceIDs
import struct SpaceIDs.AccountID
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceIDs.GroupID
import StructuredQueries
import TenancyContract

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
    _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.mintJoinToken(token, capabilities: capabilities, createdBy: createdBy, at: createdAt, expiresAt: expiresAt) }
    return MintedJoinToken(token: token, expiresAt: expiresAt)
  }

  /// consume authenticates by the token itself: it must stay reachable without any prior credential, because the key
  /// it enrolls does not exist yet. The token dies at first use.
  public func consumeJoinToken(_ token: JoinToken, pubkey: String) async throws -> KeyRecord {
    guard JoinToken.isValid(token.rawValue), let row = cell.joinToken(Self.credentialDigest(token.rawValue)) else { throw JoinTokenRejected() }
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(row.accountID)) { try $0.consumeJoinToken(token, pubkey: pubkey, at: now) }
  }

  // The gate runs before the claiming step, so a refused revoke leaves the invite alive instead of burning it on the
  // way to the refusal.
  public func revokeJoinToken(
    _ token: JoinToken,
    revocableBy allows: @escaping @Sendable (AccountID) -> Bool,
  ) async throws -> AccountID? {
    guard JoinToken.isValid(token.rawValue) else { return nil }
    let now = dateGen.now
    let hash = Self.credentialDigest(token.rawValue)
    guard let row = cell.joinToken(hash), Self.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: now) else { return nil }
    let account = AccountID(rawValue: row.accountID)
    guard allows(account) else { throw JoinTokenRevocationRefused(account: account) }
    return try await worker.call(PersonCell.ID(row.accountID)) { try $0.revokeJoinToken(token, at: now) }
  }
}

public struct JoinTokenRevocationRefused: Error, Equatable, Sendable {
  public let account: AccountID

  public init(account: AccountID) {
    self.account = account
  }
}

@Table("join_tokens")
struct EnrollmentTokenRow {
  @Column("token_hash", primaryKey: true) var tokenHash: String
  @Column("account_id") var accountID: String
  var capabilities: String
  @Column("created_by") var createdBy: String?
  @Column("created_at") var createdAt: String
  @Column("expires_at") var expiresAt: String
  var grp: String
  var owner: String
}
