#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import GRDB
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

public enum Actor: Hashable, Sendable {
  case session(SessionID)
  case person(persona: String, account: AccountID)
  case anonymous
}

/// Who acts, and in which group: a session's own group, a person's chosen one.
public struct Principal: Hashable, Sendable {
  public let actor: Actor
  public let group: GroupID

  public init(actor: Actor, group: GroupID) {
    self.actor = actor
    self.group = group
  }

  public static func shared(_ actor: Actor) -> Principal {
    Principal(actor: actor, group: .shared)
  }

  /// The actor as conversations name their members; nil for the --dev seat.
  public var member: String? {
    switch actor {
    case let .session(id): id.rawValue
    case let .person(persona, _): persona
    case .anonymous: nil
    }
  }

  /// The same person speaking as `persona`, one of its account's, verified by
  /// the caller; a session or the --dev seat is unchanged.
  public func speaking(as persona: String) -> Principal {
    guard case let .person(_, account) = actor else { return self }
    return Principal(actor: .person(persona: persona, account: account), group: group)
  }
}

public struct GroupRecord: Hashable, Sendable {
  public let id: GroupID
  public let alias: String?
  public let createdAt: Date
  /// The person whose own group this is; nil for an ordinary group.
  public let personalAccount: AccountID?
  public let visibility: GroupVisibility
  public let secretsScope: ReachScope
  public let removedAt: Date?
}

extension Space {
  public func groups() async throws -> [GroupRecord] {
    try await writer.read { db in
      try GroupRow.order { ($0.createdAt, $0.id) }.fetchAll(db).map(Self.groupRecord(from:))
    }
  }

  public func group(_ id: GroupID) async throws -> GroupRecord? {
    try await writer.read { db in
      guard let row = try GroupRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db), row.removedAt == nil else { return nil }
      return Self.groupRecord(from: row)
    }
  }

  /// The groups sessions acting in `group` read.
  public func reads(_ group: GroupID) async throws -> Set<GroupID> {
    try await writer.read { db in try GroupAccess.reach(of: group, in: db) }
  }

  /// The groups `principal` reads.
  public func reads(for principal: Principal) async throws -> Set<GroupID> {
    try await writer.read { db in
      try GroupAccess.readable(by: principal.actor, acting: principal.group, in: db)
    }
  }

  /// A live group: one that exists and was not removed.
  public func groupExists(_ group: GroupID) async throws -> Bool {
    try await writer.read { db in
      guard let row = try GroupRow.where({ $0.id.eq(group.rawValue) }).fetchOne(db) else { return false }
      return row.removedAt == nil
    }
  }

  /// The groups an account is listed in, by any role.
  public func memberGroups(of account: AccountID) async throws -> Set<GroupID> {
    try await writer.read { db in
      Set(try String.fetchAll(
        db,
        sql: """
        SELECT r.grp FROM group_roles r JOIN groups g ON g.id = r.grp
        WHERE r.account_id = ? AND g.removed_at IS NULL
        """,
        arguments: [account.rawValue],
      ).map(GroupID.init(rawValue:)))
    }
  }

  /// A session acts in its own group.
  public func principal(of session: SessionID) async throws -> Principal {
    try await writer.read { db in Principal(actor: .session(session), group: try Sessions.group(of: session.rawValue, in: db)) }
  }

  /// What `actor` may do in `group` acting out of `acting`.
  public func role(of actor: Actor, in group: GroupID, acting: GroupID) async throws -> GroupRole? {
    try await writer.read { db in try GroupAccess.role(of: actor, in: group, acting: acting, in: db) }
  }

  public func role(of principal: Principal, in group: GroupID) async throws -> GroupRole? {
    try await role(of: principal.actor, in: group, acting: principal.group)
  }

  /// Whether `group` may write `target`: the same role a machine's or a
  /// secret's switch reads.
  public func writes(_ group: GroupID, in target: GroupID) async throws -> Bool {
    try await writer.read { db in try GroupAccess.writes(group, in: target, in: db) }
  }

  /// The groups `principal` may write: its role in each is write or admin.
  public func writableGroups(for principal: Principal) async throws -> Set<GroupID> {
    try await writer.read { db in
      let snapshot = try GroupAccess.Snapshot(db)
      switch principal.actor {
      case .anonymous:
        return try GroupAccess.reach(of: principal.group, in: db)
      case let .session(id):
        guard let session = try GroupAccess.sessionRow(id, in: db) else { return [] }
        return Set(snapshot.all.filter { (snapshot.role(of: session, in: $0.rawValue) ?? .read) >= .write })
      case let .person(_, account):
        guard let row = try GroupAccess.accountRow(account, in: db) else { return [] }
        return Set(snapshot.all.filter {
          (snapshot.role(of: row, in: $0.rawValue, acting: principal.group.rawValue) ?? .read) >= .write
        })
      }
    }
  }

  public func isAdmin(_ actor: Actor, of group: GroupID, acting: GroupID) async throws -> Bool {
    try await role(of: actor, in: group, acting: acting) == .admin
  }

  /// Every group `actor` administers, by the same rule as `isAdmin`, in one read.
  public func administeredGroups(by actor: Actor, acting: GroupID) async throws -> Set<GroupID> {
    try await writer.read { db in
      let snapshot = try GroupAccess.Snapshot(db)
      switch actor {
      case .anonymous:
        return []
      case let .session(id):
        guard let session = try GroupAccess.sessionRow(id, in: db) else { return [] }
        return snapshot.administered(by: session)
      case let .person(_, account):
        guard let row = try GroupAccess.accountRow(account, in: db) else { return [] }
        return snapshot.administered(by: row)
      }
    }
  }

  /// A live person holding `admin` in `group`, directly or as a space admin.
  public func isHumanAdmin(_ account: AccountID, of group: GroupID) async throws -> Bool {
    try await writer.read { db in
      guard let row = try GroupAccess.accountRow(account, in: db) else { return false }
      return try GroupAccess.Snapshot(db).isHumanAdmin(row, of: group.rawValue)
    }
  }

  public func isGuest(_ account: AccountID) async throws -> Bool {
    try await writer.read { db in try GroupAccess.isGuest(account, in: db) }
  }

  public func personalGroup(of account: AccountID) async throws -> GroupID? {
    try await writer.read { db in try Groups.personalGroup(of: account, in: db) }
  }

  @discardableResult
  public func ensurePersonalGroup(account: AccountID) async throws -> GroupID {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    let rng = rng
    return try await writer.write { db in
      try Groups.ensurePersonalGroup(account: account, created: created, rng: rng, in: db)
    }
  }

  /// A group's list: visible to anyone who can read it.
  public func grants(of group: GroupID, by principal: Principal) async throws -> [GroupGrant] {
    try await writer.read { db in
      if case .anonymous = principal.actor { return try GroupAccess.Snapshot(db).grants(of: group.rawValue) }
      guard try GroupAccess.role(of: principal.actor, in: group, acting: principal.group, in: db) != nil else {
        throw SpaceError.groupForbidden(group.rawValue)
      }
      return try GroupAccess.Snapshot(db).grants(of: group.rawValue)
    }
  }

  public func setGrant(
    _ subject: GroupGrant.Subject, _ id: String, role: GroupRole, in group: GroupID, by actor: Actor, acting: GroupID,
  ) async throws {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      // A settings admin row is the account admin verb's to set: it guards the
      // last admin, which a list edit would bypass.
      guard group != .settings else { throw SpaceError.settingsGroupAccess }
      try GroupAccess.requireAdmin(actor, of: group, acting: acting, in: db)
      let snapshot = try GroupAccess.Snapshot(db)
      guard let target = snapshot.live(group.rawValue) else { throw SpaceError.groupForbidden(group.rawValue) }
      guard target.personalAccount == nil else { throw SpaceError.personalGroupPrivate(group.rawValue) }
      try Self.requireGrantSubject(subject, id, role: role, in: group, in: db)
      try db.execute(sql: "DELETE FROM group_roles WHERE grp = ? AND \(Self.grantSubjectColumn(subject)) = ?", arguments: [group.rawValue, id])
      try db.execute(
        sql: """
        INSERT INTO group_roles (\(Self.grantSubjectColumn(subject)), grp, role, created_at) VALUES (?, ?, ?, ?)
        """,
        arguments: [id, group.rawValue, role.rawValue, created],
      )
    }
  }

  public func removeGrant(_ subject: GroupGrant.Subject, _ id: String, in group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try await writer.write { db in
      guard group != .settings else { throw SpaceError.settingsGroupAccess }
      try GroupAccess.requireAdmin(actor, of: group, acting: acting, in: db)
      let snapshot = try GroupAccess.Snapshot(db)
      guard let target = snapshot.live(group.rawValue) else { throw SpaceError.groupForbidden(group.rawValue) }
      guard target.personalAccount == nil else { throw SpaceError.personalGroupPrivate(group.rawValue) }
      try db.execute(sql: "DELETE FROM group_roles WHERE grp = ? AND \(Self.grantSubjectColumn(subject)) = ?", arguments: [group.rawValue, id])
      guard db.changesCount > 0 else { throw SpaceError.notFound(id) }
    }
  }

  /// No group is listed in itself, and a guest is no admin.
  private static func requireGrantSubject(
    _ subject: GroupGrant.Subject, _ id: String, role: GroupRole, in group: GroupID, in db: Database,
  ) throws {
    switch subject {
    case .account:
      guard let account = try GroupAccess.accountRow(AccountID(rawValue: id), in: db), account.removedAt == nil else {
        throw SpaceError.notFound(id)
      }
      guard !(role == .admin && account.guest) else { throw SpaceError.groupForbidden(group.rawValue) }
    case .group:
      guard id != group.rawValue else { throw SpaceError.groupForbidden(group.rawValue) }
      guard let target = try GroupRow.where({ $0.id.eq(id) }).fetchOne(db), target.removedAt == nil else {
        throw SpaceError.notFound(id)
      }
    }
  }

  private static func grantSubjectColumn(_ subject: GroupGrant.Subject) -> String {
    subject == .account ? "account_id" : "source_group"
  }

  /// Opens a group to every member, or closes it back to its list.
  public func setVisibility(_ visibility: GroupVisibility, of group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try await writer.write { db in
      try GroupAccess.requireAdmin(actor, of: group, acting: acting, in: db)
      guard let target = try GroupRow.where({ $0.id.eq(group.rawValue) }).fetchOne(db), target.removedAt == nil else {
        throw SpaceError.groupForbidden(group.rawValue)
      }
      guard target.personalAccount == nil, group != .settings else { throw SpaceError.groupForbidden(group.rawValue) }
      try db.execute(
        sql: "UPDATE groups SET visibility = ? WHERE id = ?", arguments: [visibility.rawValue, group.rawValue],
      )
    }
  }

  /// Whether a group's secrets open to its owner group alone or to everyone who
  /// can reach it.
  public func setSecretsScope(_ scope: ReachScope, of group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try await writer.write { db in
      try GroupAccess.requireAdmin(actor, of: group, acting: acting, in: db)
      try db.execute(
        sql: "UPDATE groups SET secrets_scope = ? WHERE id = ?", arguments: [scope.rawValue, group.rawValue],
      )
    }
  }

  private static func groupRecord(from row: GroupRow) -> GroupRecord {
    GroupRecord(
      id: GroupID(rawValue: row.id),
      alias: row.alias,
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      personalAccount: row.personalAccount.map(AccountID.init(rawValue:)),
      visibility: GroupVisibility(rawValue: row.visibility)!,
      secretsScope: ReachScope(rawValue: row.secretsScope)!,
      removedAt: row.removedAt.flatMap { try? SQLiteDateFormat.date(from: $0) },
    )
  }
}

enum Groups {
  static func personalGroup(of account: AccountID, in db: Database) throws -> GroupID? {
    try String.fetchOne(
      db, sql: "SELECT id FROM groups WHERE personal_account = ? AND removed_at IS NULL ORDER BY created_at, id LIMIT 1",
      arguments: [account.rawValue],
    ).map(GroupID.init(rawValue:))
  }

  /// Writes `account`'s `role` in `group`, idempotently.
  static func grant(_ role: GroupRole, in group: GroupID, to account: AccountID, created: String, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM group_roles WHERE account_id = ? AND grp = ?", arguments: [account.rawValue, group.rawValue],
    )
    try db.execute(
      sql: "INSERT INTO group_roles (account_id, grp, role, created_at) VALUES (?, ?, ?, ?)",
      arguments: [account.rawValue, group.rawValue, role.rawValue, created],
    )
  }

  static func revoke(_ role: GroupRole, in group: GroupID, from account: AccountID, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM group_roles WHERE grp = ? AND account_id = ? AND role = ?",
      arguments: [group.rawValue, account.rawValue, role.rawValue],
    )
  }

  /// A human's personal group, created on first need. Its id is the account's earliest persona, else the
  /// persona allocation drawn for the account ahead of its first persona.
  static func ensurePersonalGroup(
    account: AccountID,
    created: String,
    rng: WithRandomNumberGenerator,
    in db: Database,
  ) throws -> GroupID {
    if let existing = try personalGroup(of: account, in: db) { return existing }
    let name: String
    if let persona = try String.fetchOne(
      db, sql: "SELECT name FROM personas WHERE account_id = ? ORDER BY allocation LIMIT 1", arguments: [account.rawValue],
    ) {
      name = persona
    } else if let reserved = try reservedPersona(of: account, in: db) {
      name = reserved.name
    } else {
      let minted = try Allocations.mintSecretCandidateIfUnfrozen(rng, in: db)
      name = try Allocations.draw(.persona, createdBy: account.rawValue, created: created, minted: minted, in: db).name
    }
    let group = GroupID(rawValue: name)
    try db.execute(
      sql: "INSERT INTO groups (id, created_at, personal_account) VALUES (?, ?, ?)", arguments: [name, created, account.rawValue],
    )
    try grant(.admin, in: group, to: account, created: created, in: db)
    return group
  }

  /// The persona allocation drawn for a human account before it adopted a persona.
  static func reservedPersona(of account: AccountID, in db: Database) throws -> (id: Int64, name: String)? {
    guard let id = try Int64.fetchOne(
      db, sql: """
      SELECT id FROM allocations
      WHERE kind = 'persona' AND created_by = ? AND id NOT IN (SELECT allocation FROM personas)
      ORDER BY id LIMIT 1
      """,
      arguments: [account.rawValue],
    ), let name = try Allocations.name(of: id, in: db) else { return nil }
    return (id, name)
  }
}
