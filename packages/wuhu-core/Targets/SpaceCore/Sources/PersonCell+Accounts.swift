import enum Assertion.VerifyingKey
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

extension PersonCell {
  public func account() -> AccountRecord? {
    db.rows(PersonAccountRow.where { $0.id.eq(id.key) }.select {
      PersonAccountRead.Columns(row: $0, admin: #sql("EXISTS(SELECT 1 FROM group_roles WHERE grp = \(bind: GroupID.settings.rawValue) AND account_id = \($0.id) AND role = 'admin')", as: Bool.self))
    }).first?.record
  }

  mutating func create(kind: AccountKind, name: String?, guest: Bool, at now: Date) throws -> AccountID {
    try db.execute(PersonAccountRow.insert { PersonAccountRow(id: id.key, kind: kind.rawValue, name: name, guest: guest, createdAt: SQLiteDateFormat.string(from: now), removedAt: nil, owner: id.key) })
    return AccountID(rawValue: id.key)
  }

  mutating func removeAccount(at now: Date) throws -> (keys: Int, readSessions: Int) {
    try requireAccount()
    let stamp = SQLiteDateFormat.string(from: now)
    try db.execute(PersonAccountRow.where { $0.id.eq(id.key) }.update { $0.removedAt = #bind(stamp) })
    let purged = try purgeCredentials()
    ctx.send(SpaceCell.ID("space")).dropGrants(of: AccountID(rawValue: id.key))
    return purged
  }

  mutating func addKey(_ pubkey: String, capabilities: Set<KeyCapability>, createdBy: AccountID?, at now: Date, expiresAt: Date?) throws -> KeyRecord {
    try requireAccount()
    guard VerifyingKey(label: pubkey) != nil else { throw SpaceError.malformedPubkey(pubkey) }
    guard ctx.cell(SpaceCell.ID("space")).keyRecord(pubkey: pubkey) == nil else { throw SpaceError.alreadyExists(pubkey) }
    let row = PersonKeyRow(pubkey: pubkey, accountID: id.key, capabilities: Space.stored(capabilities), createdBy: createdBy?.rawValue, createdAt: SQLiteDateFormat.string(from: now), expiresAt: expiresAt.map(SQLiteDateFormat.string(from:)), owner: id.key)
    try db.execute(PersonKeyRow.insert { row })
    return row.record
  }

  public func keys() -> [KeyRecord] {
    db.rows(PersonKeyRow.where { $0.accountID.eq(id.key) }.order { ($0.createdAt, $0.pubkey) }).map(\.record)
  }

  mutating func removeKey(_ pubkey: String) throws -> Bool {
    guard !db.rows(PersonKeyRow.where { $0.accountID.eq(id.key) && $0.pubkey.eq(pubkey) }).isEmpty else { throw SpaceError.notFound(pubkey) }
    try db.execute(PersonKeyRow.where { $0.accountID.eq(id.key) && $0.pubkey.eq(pubkey) }.delete())
    return true
  }

  mutating func createReadSession(_ token: ReadSessionToken, group: GroupID, at now: Date, expiresAt: Date, supersedes: ReadSessionToken?) throws -> Bool {
    try requireAccount()
    let stamp = SQLiteDateFormat.string(from: now)
    try db.execute(PersonReadSessionRow.where { $0.accountID.eq(id.key) && $0.expiresAt <= stamp }.delete())
    if let supersedes { _ = try deleteReadSession(supersedes) }
    try db.execute(PersonReadSessionRow.insert {
      PersonReadSessionRow(tokenHash: Space.credentialDigest(token.rawValue), accountID: id.key, createdAt: stamp, expiresAt: SQLiteDateFormat.string(from: expiresAt), group: group == .shared ? nil : group.rawValue, owner: id.key)
    })
    return true
  }

  mutating func deleteReadSession(_ token: ReadSessionToken) throws -> Bool {
    let hash = Space.credentialDigest(token.rawValue)
    try db.execute(PersonReadSessionRow.where { $0.accountID.eq(id.key) && $0.tokenHash.eq(hash) }.delete())
    return true
  }

  mutating func resetCredentials() throws -> (keys: Int, readSessions: Int) {
    try requireAccount()
    let purged = try purgeCredentials()
    for machine in db.rows(MachineRow.where { $0.accountID.eq(id.key) }) { ctx.send(MachineCell.ID(machine.id)).closeBoxes() }
    return purged
  }

  func requireAccount() throws {
    guard !db.rows(PersonAccountRow.where { $0.id.eq(id.key) && $0.removedAt.is(nil) }).isEmpty else { throw SpaceError.notFound(id.key) }
  }

  mutating func purgeCredentials() throws -> (keys: Int, readSessions: Int) {
    let keys = db.rows(PersonKeyRow.where { $0.accountID.eq(id.key) }).count
    let sessions = db.rows(PersonReadSessionRow.where { $0.accountID.eq(id.key) }).count
    try db.execute(PersonKeyRow.where { $0.accountID.eq(id.key) }.delete())
    try db.execute(PersonReadSessionRow.where { $0.accountID.eq(id.key) }.delete())
    try db.execute(EnrollmentTokenRow.where { $0.accountID.eq(id.key) }.delete())
    return (keys, sessions)
  }
}

@Table("accounts")
struct PersonAccountRow {
  @Column(primaryKey: true) var id: String
  var kind: String
  var name: String?
  var guest: Bool
  @Column("created_at") var createdAt: String
  @Column("removed_at") var removedAt: String?
  var owner: String

  func record(admin: Bool) -> AccountRecord {
    AccountRecord(id: AccountID(rawValue: id), kind: AccountKind(rawValue: kind)!, name: name, isAdmin: admin, guest: guest, createdAt: try! SQLiteDateFormat.date(from: createdAt), removedAt: removedAt.map { try! SQLiteDateFormat.date(from: $0) })
  }
}

@Table("account_keys")
struct PersonKeyRow {
  @Column(primaryKey: true) var pubkey: String
  @Column("account_id") var accountID: String
  var capabilities: String
  @Column("created_by") var createdBy: String?
  @Column("created_at") var createdAt: String
  @Column("expires_at") var expiresAt: String?
  var owner: String

  var record: KeyRecord {
    KeyRecord(pubkey: pubkey, account: AccountID(rawValue: accountID), capabilities: Space.capabilitySet(capabilities)!, createdBy: createdBy.map(AccountID.init(rawValue:)), createdAt: try! SQLiteDateFormat.date(from: createdAt), expiresAt: expiresAt.map { try! SQLiteDateFormat.date(from: $0) })
  }
}

@Table("read_sessions")
struct PersonReadSessionRow {
  @Column("token_hash", primaryKey: true) var tokenHash: String
  @Column("account_id") var accountID: String
  @Column("created_at") var createdAt: String
  @Column("expires_at") var expiresAt: String
  @Column("grp") var group: String?
  var owner: String
}

@Selection
struct PersonAccountRead {
  var row: PersonAccountRow
  var admin: Bool

  var record: AccountRecord { row.record(admin: admin) }
}
