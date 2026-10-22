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
  public func addMachineV2(name: String, group: GroupID = .shared, scope: ReachScope = .owner) async throws -> (machine: MachineRecord, token: MintedJoinToken) {
    guard let name = MachineName.normalized(name) else { throw SpaceError.invalidMachineName(name) }
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
      try MachineRow.insert {
        MachineRow(id: id.rawValue, accountID: account.rawValue, name: name, createdAt: stamp, grp: group.rawValue, scope: scope.rawValue)
      }.execute(db)
      try MachineV2MemberRow.insert { MachineV2MemberRow(machineID: id.rawValue, grp: group.rawValue, createdAt: stamp) }.execute(db)
      try EnrollmentTokenRow.insert {
        EnrollmentTokenRow(tokenHash: Self.credentialDigest(token.rawValue), accountID: account.rawValue, capabilities: Self.stored([.execMachine]), createdBy: nil, createdAt: stamp, expiresAt: SQLiteDateFormat.string(from: expiresAt), grp: GroupID.shared.rawValue)
      }.execute(db)
    }
    return (MachineRecord(id: id, account: account, name: name, createdAt: createdAt, group: group, scope: scope), MintedJoinToken(token: token, expiresAt: expiresAt))
  }

  /// One-call enrollment for a machine whose key already exists on the caller's
  /// side (the Wuhu app): the machine, its account, its v2 membership, its live
  /// key and an optional device link commit in one transaction, with no join
  /// token in between. The name is unique across v1 and v2.
  ///
  /// `enrolledBy`, when given, must own `device`; a device it does not own is
  /// reported as unknown.
  ///
  /// Replaying is idempotent: when `name` is already held by a v2 machine in
  /// `group` whose live exec-machine key is `pubkey` and was enrolled by the
  /// same person, the call returns that machine and key unchanged (re-applying
  /// the device link). Anything else holding the name is `machineNameTaken`.
  /// An unattributed enrollment (`enrolledBy` nil, the dev seat) never replays:
  /// there is no person to match.
  public func enrollMachineV2(
    name raw: String,
    group: GroupID,
    pubkey: String,
    device: String? = nil,
    enrolledBy: AccountID? = nil,
  ) async throws -> MachineV2Enrollment {
    guard let name = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let account = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let now = dateGen.now
    let stamp = SQLiteDateFormat.string(from: now)
    return try await writer.write { db in
      var linked: DeviceRow?
      if let device {
        guard let row = try DeviceRow.where({ $0.id.eq(device) }).fetchOne(db),
              enrolledBy == nil || row.accountID == enrolledBy?.rawValue else { throw SpaceError.unknownDevice(device) }
        linked = row
      }
      if let replayed = try Self.replayedEnrollment(name: name, group: group, pubkey: pubkey, enrolledBy: enrolledBy, at: now, in: db) {
        if var linked, linked.machineID != replayed.machine.id.rawValue {
          linked.machineID = replayed.machine.id.rawValue
          try DeviceRow.upsert { linked }.execute(db)
        }
        return replayed
      }
      try Self.requireMachineNameFree(name, besides: nil, in: db)
      try EnrollmentMachineAccountRow.insert {
        EnrollmentMachineAccountRow(id: account.rawValue, kind: AccountKind.machine.rawValue, name: name, createdAt: stamp, removedAt: nil)
      }.execute(db)
      let row = MachineRow(id: id.rawValue, accountID: account.rawValue, name: name, createdAt: stamp, grp: group.rawValue, scope: ReachScope.owner.rawValue)
      try MachineRow.insert { row }.execute(db)
      try MachineV2MemberRow.insert { MachineV2MemberRow(machineID: id.rawValue, grp: group.rawValue, createdAt: stamp) }.execute(db)
      let key = try Self.insertKey(pubkey, account: account, capabilities: [.execMachine], createdBy: enrolledBy, createdAt: now, expiresAt: nil, in: db)
      if var linked {
        linked.machineID = id.rawValue
        try DeviceRow.upsert { linked }.execute(db)
      }
      return MachineV2Enrollment(machine: Self.machineRecord(from: row), key: key)
    }
  }

  private static func replayedEnrollment(name: String, group: GroupID, pubkey: String, enrolledBy: AccountID?, at now: Date, in db: Database) throws -> MachineV2Enrollment? {
    guard let enrolledBy,
          let holder = try MachineRow.where({ $0.name.lower().eq(name) }).fetchOne(db), holder.grp == group.rawValue,
          try MachineV2MemberRow.where({ $0.machineID.eq(holder.id) }).fetchOne(db) != nil,
          let stored = try Row.fetchOne(db, sql: "SELECT * FROM account_keys WHERE pubkey = ? AND account_id = ?", arguments: [pubkey, holder.accountID]),
          let key = try? keyRecord(from: stored), isLive(key.expiresAt, at: now), key.capabilities.contains(.execMachine),
          key.createdBy == enrolledBy
    else { return nil }
    return MachineV2Enrollment(machine: machineRecord(from: holder), key: key)
  }

  /// A machine's own revocation. One transaction checks that `pubkey` is a
  /// live exec-machine key of `machine`'s account and purges every credential
  /// of that account, so a rotation can only land wholly before (the key is
  /// dead: false) or wholly after it. The machine row stays.
  public func revokeMachine(_ machine: MachineID, presenting pubkey: String) async throws -> Bool {
    let now = dateGen.now
    return try await writer.write { db in
      guard let row = try MachineRow.where({ $0.id.eq(machine.rawValue) }).fetchOne(db),
            let stored = try Row.fetchOne(db, sql: "SELECT * FROM account_keys WHERE pubkey = ? AND account_id = ?", arguments: [pubkey, row.accountID]),
            let key = try? Self.keyRecord(from: stored), Self.isLive(key.expiresAt, at: now), key.capabilities.contains(.execMachine)
      else { return false }
      _ = try Self.purgeCredentials(account: key.account, in: db)
      return true
    }
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
      try db.execute(sql: "DELETE FROM join_token_receipts WHERE expires_at <= ?", arguments: [SQLiteDateFormat.string(from: now)])
      guard let row = try EnrollmentTokenRow.where({ $0.tokenHash.eq(hash) }).fetchOne(db) else {
        // Already consumed: the same pubkey replays to the key it enrolled,
        // while that key lives; any other pubkey is refused as before.
        guard let receipt = try Row.fetchOne(db, sql: "SELECT pubkey FROM join_token_receipts WHERE token_hash = ?", arguments: [hash]),
              receipt["pubkey"] as String == pubkey,
              let stored = try Row.fetchOne(db, sql: "SELECT * FROM account_keys WHERE pubkey = ?", arguments: [pubkey]),
              let key = try? Self.keyRecord(from: stored), Self.isLive(key.expiresAt, at: now),
              try !machineV2 || Self.isMachineV2Account(key.account.rawValue, in: db)
        else { throw JoinTokenRejected() }
        return key
      }
      if machineV2 {
        guard try Self.isMachineV2Account(row.accountID, in: db) else { throw JoinTokenRejected() }
      }
      guard try Self.isLive(SQLiteDateFormat.date(from: row.expiresAt), at: now) else {
        throw JoinTokenRejected()
      }
      guard let capabilities = Self.capabilitySet(row.capabilities) else {
        throw CorruptCredentialRow(stored: row.capabilities)
      }
      try EnrollmentTokenRow.where { $0.tokenHash.eq(hash) }.delete().execute(db)
      let key = try Self.insertKey(
        pubkey,
        account: AccountID(rawValue: row.accountID),
        capabilities: capabilities,
        createdBy: row.createdBy.map(AccountID.init(rawValue:)),
        createdAt: now,
        expiresAt: nil,
        in: db,
      )
      // Person invites stay strictly one-time ("dies at first use"); only a
      // machine's enroll or re-key, whose box retries on its own, replays.
      if try MachineRow.where({ $0.accountID.eq(row.accountID) }).fetchOne(db) != nil {
        try db.execute(
          sql: "INSERT INTO join_token_receipts (token_hash, pubkey, expires_at) VALUES (?, ?, ?)",
          arguments: [hash, pubkey, row.expiresAt],
        )
      }
      return key
    }
  }

  private static func isMachineV2Account(_ account: String, in db: Database) throws -> Bool {
    guard let machine = try MachineRow.where({ $0.accountID.eq(account) }).fetchOne(db) else { return false }
    return try MachineV2MemberRow.where({ $0.machineID.eq(machine.id) && $0.grp.eq(machine.grp) }).fetchOne(db) != nil
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

public struct MachineV2Enrollment: Equatable, Sendable {
  public let machine: MachineRecord
  public let key: KeyRecord
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
