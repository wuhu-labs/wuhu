#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import StructuredQueries
import WuweiQueries

extension PersonCell {
  mutating func mintJoinToken(_ token: JoinToken, capabilities: Set<KeyCapability>, createdBy: AccountID?, at now: Date, expiresAt: Date) throws -> Bool {
    try requireAccount()
    try db.execute(EnrollmentTokenRow.insert {
      EnrollmentTokenRow(tokenHash: Space.credentialDigest(token.rawValue), accountID: id.key, capabilities: Space.stored(capabilities), createdBy: createdBy?.rawValue, createdAt: SQLiteDateFormat.string(from: now), expiresAt: SQLiteDateFormat.string(from: expiresAt), grp: GroupID.shared.rawValue, owner: id.key)
    })
    return true
  }

  /// A person's invite dies at first use; a machine's enrol or re-key writes a receipt instead, so its box may retry
  /// with the same key until the token's own expiry passes.
  mutating func consumeJoinToken(_ token: JoinToken, pubkey: String, at now: Date) throws -> KeyRecord {
    let hash = Space.credentialDigest(token.rawValue)
    guard let row = db.rows(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }).first else {
      // A machine's box retries a lost answer: the token is spent, and the receipt names the key it enrolled.
      guard let receipt = db.rows(PersonReceiptRow.where { $0.owner.eq(id.key) && $0.tokenHash.eq(hash) }).first,
            receipt.pubkey == pubkey, Space.isLive(try SQLiteDateFormat.date(from: receipt.expiresAt), at: now),
            let key = db.rows(PersonKeyRow.where { $0.accountID.eq(id.key) && $0.pubkey.eq(pubkey) }).first?.record,
            Space.isLive(key.expiresAt, at: now)
      else { throw JoinTokenRejected() }
      return key
    }
    guard Space.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: now) else { throw JoinTokenRejected() }
    try db.execute(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }.delete())
    let key = try addKey(pubkey, capabilities: Space.capabilitySet(row.capabilities)!, createdBy: row.createdBy.map(AccountID.init(rawValue:)), at: now, expiresAt: nil)
    if account()?.kind == .machine {
      let stamp = SQLiteDateFormat.string(from: now)
      try db.execute(PersonReceiptRow.where { $0.owner.eq(id.key) && $0.expiresAt.lte(stamp) }.delete())
      try db.execute(PersonReceiptRow.insert { PersonReceiptRow(tokenHash: hash, pubkey: pubkey, expiresAt: row.expiresAt, owner: id.key) })
    }
    return key
  }

  mutating func revokeJoinToken(_ token: JoinToken, at now: Date) throws -> AccountID? {
    let hash = Space.credentialDigest(token.rawValue)
    guard let row = db.rows(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }).first,
          Space.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: now) else { return nil }
    try db.execute(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }.delete())
    return AccountID(rawValue: id.key)
  }
}

@Table("join_token_receipts")
struct PersonReceiptRow {
  @Column("token_hash", primaryKey: true) var tokenHash: String
  var pubkey: String
  @Column("expires_at") var expiresAt: String
  var owner: String
}
