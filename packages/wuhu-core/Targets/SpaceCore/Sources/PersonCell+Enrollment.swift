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
      EnrollmentTokenRow(tokenHash: Space.credentialDigest(token.rawValue), accountID: id.key, capabilities: Space.stored(capabilities), createdBy: createdBy?.rawValue, createdAt: SQLiteDateFormat.string(from: now), expiresAt: SQLiteDateFormat.string(from: expiresAt), grp: GroupID.shared.rawValue)
    })
    return true
  }

  mutating func consumeJoinToken(_ token: JoinToken, pubkey: String, at now: Date) throws -> KeyRecord {
    let hash = Space.credentialDigest(token.rawValue)
    guard let row = db.rows(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }).first,
          Space.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: now) else { throw JoinTokenRejected() }
    try db.execute(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }.delete())
    return try addKey(pubkey, capabilities: Space.capabilitySet(row.capabilities)!, createdBy: row.createdBy.map(AccountID.init(rawValue:)), at: now, expiresAt: nil)
  }

  mutating func revokeJoinToken(_ token: JoinToken, at now: Date) throws -> AccountID? {
    let hash = Space.credentialDigest(token.rawValue)
    guard let row = db.rows(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }).first,
          Space.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: now) else { return nil }
    try db.execute(EnrollmentTokenRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }.delete())
    return AccountID(rawValue: id.key)
  }
}
