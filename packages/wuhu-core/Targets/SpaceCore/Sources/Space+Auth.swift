import enum Assertion.VerifyingKey
import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

extension Space {
  public func addAccount(kind: AccountKind, name: String?, admin: Bool = false, guest: Bool = false) async throws -> AccountRecord {
    if let name, name.lowercased() == Notifications.ownerRecipient { throw SpaceError.reservedAccountName(name) }
    if (admin || guest), kind != .human { throw SpaceError.notAPerson(name ?? kind.rawValue) }
    if admin, guest { throw SpaceError.notAPerson(name ?? kind.rawValue) }
    let id = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let createdAt = dateGen.now
    _ = try await worker.call(PersonCell.ID(id.rawValue)) { try $0.create(kind: kind, name: name, guest: guest, at: createdAt) }
    if kind == .human, !guest { _ = try await ensurePersonalGroup(account: id) }
    if admin { return try await setAdmin(id, admin: true) }
    return AccountRecord(id: id, kind: kind, name: name, isAdmin: false, guest: guest, createdAt: createdAt, removedAt: nil)
  }

  public func account(_ id: AccountID) async throws -> AccountRecord? { cell.account(id) }
  public func accounts() async throws -> [AccountRecord] { cell.accounts() }
  public func hasAdminAccount() async throws -> Bool { cell.hasAdminAccount() }

  public func setAdmin(_ id: AccountID, admin: Bool) async throws -> AccountRecord {
    guard let record = worker.cell(PersonCell.ID(id.rawValue)).account(), record.removedAt == nil else { throw SpaceError.notFound(id.rawValue) }
    if admin, record.kind != .human || record.guest { throw SpaceError.notAPerson(id.rawValue) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    _ = try await worker.call(GroupCell.ID(GroupID.settings.rawValue)) { try $0.setAdmin(id, admin: admin, at: stamp) }
    guard let record = cell.account(id) else { throw SpaceError.notFound(id.rawValue) }
    return record
  }

  public func removeAccount(_ id: AccountID) async throws -> (keys: Int, readSessions: Int) {
    _ = try await setAdmin(id, admin: false)
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(id.rawValue)) { try $0.removeAccount(at: now) }
  }

  public func addKey(_ pubkey: String, account: AccountID, capabilities: Set<KeyCapability>, createdBy: AccountID?, expiresAt: Date?) async throws -> KeyRecord {
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(account.rawValue)) { try $0.addKey(pubkey, capabilities: capabilities, createdBy: createdBy, at: now, expiresAt: expiresAt) }
  }

  public func keyRecord(pubkey: String) async throws -> KeyRecord? { cell.keyRecord(pubkey: pubkey) }
  public func keys(account: AccountID) async throws -> [KeyRecord] { worker.cell(PersonCell.ID(account.rawValue)).keys() }
  public func credential(pubkey: String) async throws -> KeyRecord? {
    guard let record = cell.keyRecord(pubkey: pubkey), Self.isLive(record.expiresAt, at: dateGen.now) else { return nil }
    return record
  }

  public func removeKey(pubkey: String) async throws {
    guard let key = cell.keyRecord(pubkey: pubkey) else { throw SpaceError.notFound(pubkey) }
    _ = try await worker.call(PersonCell.ID(key.account.rawValue)) { try $0.removeKey(pubkey) }
  }

  public func createReadSession(account: AccountID, group: GroupID, expiresAt: Date, supersedes: ReadSessionToken? = nil) async throws -> ReadSessionToken {
    let token = ReadSessionToken(rawValue: ReadSessionToken.prefix + randomSuffix(ReadSessionToken.suffixLength))
    let now = dateGen.now
    _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.createReadSession(token, group: group, at: now, expiresAt: expiresAt, supersedes: supersedes) }
    return token
  }

  public func account(readSession: ReadSessionToken, in group: GroupID) async throws -> AccountID? {
    guard ReadSessionToken.isValid(readSession.rawValue), let row = cell.readSession(readSession), (row.group ?? GroupID.shared.rawValue) == group.rawValue,
          Self.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: dateGen.now) else { return nil }
    return AccountID(rawValue: row.accountID)
  }

  public func deleteReadSession(_ token: ReadSessionToken) async throws {
    guard let row = cell.readSession(token) else { return }
    _ = try await worker.call(PersonCell.ID(row.accountID)) { try $0.deleteReadSession(token) }
  }

  public func resetCredentials(account: AccountID) async throws -> (keys: Int, readSessions: Int) {
    return try await worker.call(PersonCell.ID(account.rawValue)) { try $0.resetCredentials() }
  }

  static func purgeCredentials(account: AccountID, in db: Database) throws -> (keys: Int, readSessions: Int) {
    try db.execute(sql: "DELETE FROM account_keys WHERE account_id = ?", arguments: [account.rawValue])
    let keys = db.changesCount
    try db.execute(sql: "DELETE FROM read_sessions WHERE account_id = ?", arguments: [account.rawValue])
    let readSessions = db.changesCount
    try db.execute(sql: "DELETE FROM join_tokens WHERE account_id = ?", arguments: [account.rawValue])
    return (keys, readSessions)
  }

  static func insertKey(
    _ pubkey: String,
    account: AccountID,
    capabilities: Set<KeyCapability>,
    createdBy: AccountID?,
    createdAt: Date,
    expiresAt: Date?,
    in db: Database,
  ) throws -> KeyRecord {
    // Signature gates parse this column as a VerifyingKey; a label the parser
    // rejects must never become a row.
    guard VerifyingKey(label: pubkey) != nil else {
      throw SpaceError.malformedPubkey(pubkey)
    }
    guard try Row.fetchOne(db, sql: "SELECT 1 FROM account_keys WHERE pubkey = ?", arguments: [pubkey]) == nil else {
      throw SpaceError.alreadyExists(pubkey)
    }
    try db.execute(
      sql: "INSERT INTO account_keys (pubkey, account_id, capabilities, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
      arguments: [
        pubkey,
        account.rawValue,
        stored(capabilities),
        createdBy?.rawValue,
        SQLiteDateFormat.string(from: createdAt),
        expiresAt.map(SQLiteDateFormat.string(from:)),
      ],
    )
    return KeyRecord(
      pubkey: pubkey,
      account: account,
      capabilities: capabilities,
      createdBy: createdBy,
      createdAt: createdAt,
      expiresAt: expiresAt,
    )
  }

  struct CorruptCredentialRow: Error {
    let stored: String
  }

  // A removed account is gone for every credential-granting path.
  static func requireAccount(_ id: AccountID, in db: Database) throws {
    guard try Row.fetchOne(
      db, sql: "SELECT 1 FROM accounts WHERE id = ? AND removed_at IS NULL", arguments: [id.rawValue],
    ) != nil else {
      throw SpaceError.notFound(id.rawValue)
    }
  }

  static func keyRecord(from row: Row) throws -> KeyRecord {
    guard let capabilities = capabilitySet(row["capabilities"]) else {
      throw CorruptCredentialRow(stored: row["capabilities"])
    }
    return KeyRecord(
      pubkey: row["pubkey"],
      account: AccountID(rawValue: row["account_id"]),
      capabilities: capabilities,
      createdBy: (row["created_by"] as String?).map(AccountID.init(rawValue:)),
      createdAt: (try? SQLiteDateFormat.date(from: row["created_at"])) ?? Date(timeIntervalSince1970: 0),
      expiresAt: try (row["expires_at"] as String?).map(SQLiteDateFormat.date(from:)),
    )
  }

  static func isLive(_ expiresAt: Date?, at now: Date) -> Bool {
    expiresAt.map { now < $0 } ?? true
  }

  static func stored(_ capabilities: Set<KeyCapability>) -> String {
    capabilities.map(\.rawValue).sorted().joined(separator: " ")
  }

  static func capabilitySet(_ stored: String) -> Set<KeyCapability>? {
    var capabilities: Set<KeyCapability> = []
    for token in stored.split(separator: " ") {
      guard let capability = KeyCapability(rawValue: String(token)) else { return nil }
      capabilities.insert(capability)
    }
    return capabilities
  }

  // Tokens are 32-character CSPRNG credentials, so a plain digest is a sound
  // verifier: there is no low-entropy preimage to grind, and nothing stored
  // can be replayed as the token.
  static func credentialDigest(_ raw: String) -> String {
    hexEncoded(SHA256.hash(data: Data(raw.utf8)))
  }
}
