import enum Assertion.VerifyingKey
import Crypto
import Foundation
import GRDB
import struct SpaceContract.GroupID

extension Space {
  public func addAccount(kind: AccountKind, name: String?, admin: Bool = false) async throws -> AccountRecord {
    // "owner" (SpaceContract's ownerIdentity) is the generic principal that
    // unenrolled --dev seats act as; no account may squat it in any casing.
    if let name, name.lowercased() == Notifications.ownerRecipient {
      throw SpaceError.reservedAccountName(name)
    }
    if admin, kind != .human { throw SpaceError.notAPerson(name ?? kind.rawValue) }
    let id = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let createdAt = dateGen.now
    let created = SQLiteDateFormat.string(from: createdAt)
    let rng = rng
    try await writer.write { db in
      try db.execute(
        sql: "INSERT INTO accounts (id, kind, name, created_at) VALUES (?, ?, ?, ?)",
        arguments: [id.rawValue, kind.rawValue, name, created],
      )
      guard kind == .human else { return }
      let personal = try Groups.ensurePersonalGroup(account: id, created: created, rng: rng, in: db)
      if admin { try Groups.addEdge(src: personal, dst: .shared, kind: .admin, created: created, by: nil, in: db) }
    }
    return AccountRecord(id: id, kind: kind, name: name, isAdmin: admin, createdAt: createdAt, removedAt: nil)
  }

  public func account(_ id: AccountID) async throws -> AccountRecord? {
    try await writer.read { db in
      try Row.fetchOne(db, sql: "SELECT *, \(Groups.sharedAdminColumn) FROM accounts WHERE id = ?", arguments: [id.rawValue])
        .map(Self.accountRecord(from:))
    }
  }

  public func accounts() async throws -> [AccountRecord] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: "SELECT *, \(Groups.sharedAdminColumn) FROM accounts WHERE removed_at IS NULL ORDER BY created_at, id")
        .map(Self.accountRecord(from:))
    }
  }

  public func hasAdminAccount() async throws -> Bool {
    try await writer.read { db in
      try Self.liveAdminCount(in: db) > 0
    }
  }

  public func setAdmin(_ id: AccountID, admin: Bool) async throws -> AccountRecord {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    let rng = rng
    return try await writer.write { db in
      guard let row = try Row.fetchOne(
        db, sql: "SELECT *, \(Groups.sharedAdminColumn) FROM accounts WHERE id = ? AND removed_at IS NULL",
        arguments: [id.rawValue],
      ) else {
        throw SpaceError.notFound(id.rawValue)
      }
      let record = Self.accountRecord(from: row)
      if record.isAdmin, !admin, try Self.liveAdminCount(in: db) == 1 {
        throw SpaceError.lastAdmin(id.rawValue)
      }
      if admin, record.kind != .human { throw SpaceError.notAPerson(id.rawValue) }
      if admin {
        let personal = try Groups.ensurePersonalGroup(account: id, created: created, rng: rng, in: db)
        try Groups.addEdge(src: personal, dst: .shared, kind: .admin, created: created, by: nil, in: db)
      } else {
        let personal = try Groups.personalGroup(of: id, in: db)
        if let personal {
          try Groups.removeEdge(src: personal, dst: .shared, kind: .admin, in: db)
        }
        // Admin held through a team group is that group's to revoke: say so
        // rather than report a demotion that didn't happen.
        let granting = try Groups.adminGrantingGroups(of: id, over: .shared, in: db).filter { $0 != personal }
        if !granting.isEmpty {
          throw SpaceError.adminThroughGroup(account: id.rawValue, groups: granting.map(\.rawValue))
        }
      }
      return AccountRecord(
        id: record.id, kind: record.kind, name: record.name,
        isAdmin: admin, createdAt: record.createdAt, removedAt: nil,
      )
    }
  }

  // The row survives as a tombstone: attribution (personas, created_by, journal
  // history) keeps resolving, while every credential and credential-in-waiting
  // dies in the same transaction.
  public func removeAccount(_ id: AccountID) async throws -> (keys: Int, readSessions: Int) {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      guard let row = try Row.fetchOne(
        db, sql: "SELECT *, \(Groups.sharedAdminColumn) FROM accounts WHERE id = ? AND removed_at IS NULL",
        arguments: [id.rawValue],
      ) else {
        throw SpaceError.notFound(id.rawValue)
      }
      if Self.accountRecord(from: row).isAdmin, try Self.liveAdminCount(in: db) == 1 {
        throw SpaceError.lastAdmin(id.rawValue)
      }
      try db.execute(sql: "UPDATE accounts SET removed_at = ? WHERE id = ?", arguments: [now, id.rawValue])
      return try Self.purgeCredentials(account: id, in: db)
    }
  }

  // Outstanding join tokens are credentials-in-waiting: a purge that left one
  // alive would re-admit the account it just kicked.
  static func purgeCredentials(account: AccountID, in db: Database) throws -> (keys: Int, readSessions: Int) {
    try db.execute(sql: "DELETE FROM account_keys WHERE account_id = ?", arguments: [account.rawValue])
    let keys = db.changesCount
    try db.execute(sql: "DELETE FROM read_sessions WHERE account_id = ?", arguments: [account.rawValue])
    let readSessions = db.changesCount
    try db.execute(sql: "DELETE FROM join_tokens WHERE account_id = ?", arguments: [account.rawValue])
    return (keys: keys, readSessions: readSessions)
  }

  public func addKey(
    _ pubkey: String,
    account: AccountID,
    capabilities: Set<KeyCapability>,
    createdBy: AccountID?,
    expiresAt: Date?,
  ) async throws -> KeyRecord {
    let createdAt = dateGen.now
    return try await writer.write { db in
      try Self.requireAccount(account, in: db)
      return try Self.insertKey(
        pubkey,
        account: account,
        capabilities: capabilities,
        createdBy: createdBy,
        createdAt: createdAt,
        expiresAt: expiresAt,
        in: db,
      )
    }
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

  // Management lookup, distinct from credential(pubkey:): an expired key is
  // no credential but is still addressable, e.g. for revocation.
  public func keyRecord(pubkey: String) async throws -> KeyRecord? {
    try await writer.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM account_keys WHERE pubkey = ?", arguments: [pubkey])
        .map(Self.keyRecord(from:))
    }
  }

  public func keys(account: AccountID) async throws -> [KeyRecord] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM account_keys WHERE account_id = ? ORDER BY created_at, pubkey",
        arguments: [account.rawValue],
      ).map(Self.keyRecord(from:))
    }
  }

  // The live-key oracle behind every signature gate. A row that does not
  // decode is no credential: the request fails closed (401, not a crash), and
  // the row stays in place as evidence.
  public func credential(pubkey: String) async throws -> KeyRecord? {
    let now = dateGen.now
    let log = log
    let record = try await writer.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM account_keys WHERE pubkey = ?", arguments: [pubkey])
        .flatMap { row -> KeyRecord? in
          do {
            return try Self.keyRecord(from: row)
          } catch {
            log.warning(
              "account key row failed to decode; refusing the credential",
              metadata: ["pubkey": "\(pubkey)", "reason": "\(error)"],
            )
            return nil
          }
        }
    }
    guard let record, Self.isLive(record.expiresAt, at: now) else { return nil }
    return record
  }

  public func removeKey(pubkey: String) async throws {
    try await writer.write { db in
      try db.execute(sql: "DELETE FROM account_keys WHERE pubkey = ?", arguments: [pubkey])
      guard db.changesCount > 0 else { throw SpaceError.notFound(pubkey) }
    }
  }

  // A read session is minted on one web host and binds that host's group;
  // shared is stored as NULL, the shape every pre-group row already has.
  public func createReadSession(
    account: AccountID,
    group: GroupID,
    expiresAt: Date,
    supersedes: ReadSessionToken? = nil,
  ) async throws -> ReadSessionToken {
    let token = ReadSessionToken(rawValue: ReadSessionToken.prefix + randomSuffix(ReadSessionToken.suffixLength))
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      try Self.requireAccount(account, in: db)
      // Expired rows are unreachable by deleteReadSession; sweep the account's
      // dead rows on mint so the table cannot grow without bound.
      try db.execute(sql: "DELETE FROM read_sessions WHERE account_id = ? AND expires_at <= ?", arguments: [account.rawValue, now])
      // The re-mint on each page load supersedes the browser's current cookie:
      // drop the row it names so a browsing session leaves one live row, not one
      // per load.
      if let supersedes {
        try db.execute(sql: "DELETE FROM read_sessions WHERE token_hash = ?", arguments: [Self.credentialDigest(supersedes.rawValue)])
      }
      try db.execute(
        sql: "INSERT INTO read_sessions (token_hash, account_id, created_at, expires_at, grp) VALUES (?, ?, ?, ?, ?)",
        arguments: [
          Self.credentialDigest(token.rawValue), account.rawValue, now, SQLiteDateFormat.string(from: expiresAt),
          group == .shared ? nil : group.rawValue,
        ],
      )
      return token
    }
  }

  public func account(readSession: ReadSessionToken, in group: GroupID) async throws -> AccountID? {
    guard ReadSessionToken.isValid(readSession.rawValue) else { return nil }
    let now = dateGen.now
    return try await writer.read { db -> AccountID? in
      guard let row = try Row.fetchOne(
        db,
        sql: "SELECT account_id, expires_at FROM read_sessions WHERE token_hash = ? AND ifnull(grp, ?) = ?",
        arguments: [Self.credentialDigest(readSession.rawValue), GroupID.shared.rawValue, group.rawValue],
      ) else { return nil }
      guard try Self.isLive(SQLiteDateFormat.date(from: row["expires_at"]), at: now) else { return nil }
      return AccountID(rawValue: row["account_id"])
    }
  }

  public func deleteReadSession(_ token: ReadSessionToken) async throws {
    try await writer.write { db in
      try db.execute(sql: "DELETE FROM read_sessions WHERE token_hash = ?", arguments: [Self.credentialDigest(token.rawValue)])
    }
  }

  public func resetCredentials(account: AccountID) async throws -> (keys: Int, readSessions: Int) {
    try await writer.write { db in
      try Self.requireAccount(account, in: db)
      return try Self.purgeCredentials(account: account, in: db)
    }
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

  static func liveAdminCount(in db: Database) throws -> Int {
    try Int.fetchOne(
      db, sql: "SELECT count(*) FROM (SELECT \(Groups.sharedAdminColumn) FROM accounts WHERE removed_at IS NULL) WHERE is_admin",
    ) ?? 0
  }

  private static func accountRecord(from row: Row) -> AccountRecord {
    AccountRecord(
      id: AccountID(rawValue: row["id"]),
      kind: AccountKind(rawValue: row["kind"])!,
      name: row["name"],
      isAdmin: row["is_admin"],
      createdAt: (try? SQLiteDateFormat.date(from: row["created_at"])) ?? Date(timeIntervalSince1970: 0),
      removedAt: (row["removed_at"] as String?).flatMap { try? SQLiteDateFormat.date(from: $0) },
    )
  }

  private static func keyRecord(from row: Row) throws -> KeyRecord {
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
