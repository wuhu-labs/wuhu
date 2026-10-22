#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import GRDB
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

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
  public let createdAt: Date
  /// The person whose own group this is; nil for an ordinary group.
  public let personalAccount: AccountID?
  public let removedAt: Date?
}

/// The roles an account holds in a group. A space admin holds `admin` in the
/// settings group, which administers every group.
enum GroupRole: String, Sendable {
  case admin
}

extension Space {
  public func groups() async throws -> [GroupRecord] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: "SELECT id, created_at, personal_account, removed_at FROM groups ORDER BY created_at, id").map { row in
        GroupRecord(
          id: GroupID(rawValue: row["id"]),
          createdAt: (try? SQLiteDateFormat.date(from: row["created_at"])) ?? Date(timeIntervalSince1970: 0),
          personalAccount: (row["personal_account"] as String?).map(AccountID.init(rawValue:)),
          removedAt: (row["removed_at"] as String?).flatMap { try? SQLiteDateFormat.date(from: $0) },
        )
      }
    }
  }

  /// The groups `group` reads, itself and the settings group included.
  public func reads(_ group: GroupID) async throws -> Set<GroupID> {
    try await writer.read { db in try Groups.reads(group, in: db) }
  }

  /// A live group: one that exists and was not removed.
  public func groupExists(_ group: GroupID) async throws -> Bool {
    try await writer.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM groups WHERE id = ? AND removed_at IS NULL)", arguments: [group.rawValue],
      ) ?? false
    }
  }

  public func isMember(_ account: AccountID, of group: GroupID) async throws -> Bool {
    try await writer.read { db in try Groups.isMember(account, of: group, in: db) }
  }

  public func memberGroups(of account: AccountID) async throws -> Set<GroupID> {
    try await writer.read { db in
      Set(try String.fetchAll(
        db, sql: "SELECT grp FROM group_members WHERE account_id = ?", arguments: [account.rawValue],
      ).map(GroupID.init(rawValue:)))
    }
  }

  /// The groups any of `groups` reads, themselves included.
  public func reads(_ groups: Set<GroupID>) async throws -> Set<GroupID> {
    try await writer.read { db in
      try groups.reduce(into: []) { readable, group in readable.formUnion(try Groups.reads(group, in: db)) }
    }
  }

  /// A session acts in its own group.
  public func principal(of session: SessionID) async throws -> Principal {
    try await writer.read { db in Principal(actor: .session(session), group: try Sessions.group(of: session.rawValue, in: db)) }
  }

  /// Top-level agents (kind agent, no parent, live) in `group`, plus its admins.
  public func isAdmin(_ actor: Actor, of group: GroupID) async throws -> Bool {
    try await writer.read { db in try Groups.isAdmin(actor, of: group, in: db) }
  }

  /// Every group `actor` administers, by the same rule as `isAdmin`, in one read.
  public func administeredGroups(by actor: Actor) async throws -> Set<GroupID> {
    try await writer.read { db in try Groups.administeredGroups(by: actor, in: db) }
  }

  /// A live person holding `admin` in `group`, or in the settings group.
  public func isHumanAdmin(_ account: AccountID, of group: GroupID) async throws -> Bool {
    try await writer.read { db in try Groups.isHumanAdmin(account, of: group, in: db) }
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

  public func addReadEdge(from src: GroupID, to dst: GroupID, by creator: String? = nil) async throws {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try Groups.insertReadEdge(src: src, dst: dst, created: created, by: creator, in: db)
      try Groups.recompute(in: db)
    }
  }

  public func removeReadEdge(from src: GroupID, to dst: GroupID) async throws {
    try await writer.write { db in
      try Groups.removeReadEdge(src: src, dst: dst, in: db)
      try Groups.recompute(in: db)
    }
  }
}

enum Groups {
  /// The admin rows that make `account` a space admin: the settings group's.
  /// `account` is a SQL expression.
  static func spaceAdminSQL(account: String) -> String {
    """
    SELECT 1 FROM group_roles r
      WHERE r.grp = '\(GroupID.settings.rawValue)' AND r.account_id = \(account) AND r.role = 'admin'
    """
  }

  /// `is_admin` of an `accounts` row: a live person who is a space admin.
  static let spaceAdminColumn: String =
    "EXISTS (\(spaceAdminSQL(account: "accounts.id"))) AND accounts.kind = 'human' AS is_admin"

  /// The groups `group` reads. The settings group is every group's to read;
  /// only space admins write it.
  static func reads(_ group: GroupID, in db: Database) throws -> Set<GroupID> {
    let readable = try String.fetchAll(db, sql: "SELECT readable FROM group_reads WHERE grp = ?", arguments: [group.rawValue])
    return Set(readable.map(GroupID.init(rawValue:))).union([group, .settings])
  }

  /// Whether `account` belongs to `group`. A personal group has one member:
  /// its owner.
  static func isMember(_ account: AccountID, of group: GroupID, in db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
      SELECT EXISTS (
        SELECT 1 FROM group_members m JOIN groups g ON g.id = m.grp
        WHERE m.grp = ? AND m.account_id = ? AND (g.personal_account IS NULL OR g.personal_account = ?)
      )
      """,
      arguments: [group.rawValue, account.rawValue, account.rawValue],
    ) ?? false
  }

  static func personalGroup(of account: AccountID, in db: Database) throws -> GroupID? {
    try String.fetchOne(
      db,
      sql: "SELECT id FROM groups WHERE personal_account = ? AND removed_at IS NULL ORDER BY created_at, id LIMIT 1",
      arguments: [account.rawValue],
    ).map(GroupID.init(rawValue:))
  }

  /// Whether `group` is someone's own group.
  static func isPersonal(_ group: GroupID, in db: Database) throws -> Bool {
    try Bool.fetchOne(
      db, sql: "SELECT EXISTS (SELECT 1 FROM groups WHERE id = ? AND personal_account IS NOT NULL)",
      arguments: [group.rawValue],
    ) ?? false
  }

  static func isAdmin(_ actor: Actor, of group: GroupID, in db: Database) throws -> Bool {
    switch actor {
    case let .session(id):
      guard group != .settings else { return false }
      return try Bool.fetchOne(
        db,
        sql: """
        SELECT EXISTS (SELECT 1 FROM sessions
          WHERE id = ? AND grp = ? AND kind = 'agent' AND parent IS NULL AND lifecycle = 'live')
        """,
        arguments: [id.rawValue, group.rawValue],
      ) ?? false
    case let .person(_, account):
      return try isHumanAdmin(account, of: group, in: db)
    case .anonymous:
      return false
    }
  }

  static func administeredGroups(by actor: Actor, in db: Database) throws -> Set<GroupID> {
    let ids: [String]
    switch actor {
    case let .session(id):
      ids = try String.fetchAll(
        db,
        sql: "SELECT grp FROM sessions WHERE id = ? AND kind = 'agent' AND parent IS NULL AND lifecycle = 'live'",
        arguments: [id.rawValue],
      )
    case let .person(_, account):
      ids = try administeredGroupIDs(of: account, in: db)
    case .anonymous:
      ids = []
    }
    return Set(ids.map(GroupID.init(rawValue:)))
  }

  /// The groups the account holds `admin` in, plus, for a space admin, every
  /// group but another person's own.
  private static func administeredGroupIDs(of account: AccountID, in db: Database) throws -> [String] {
    guard try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM accounts a WHERE a.id = ? AND a.kind = 'human' AND a.removed_at IS NULL)",
      arguments: [account.rawValue],
    ) == true else { return [] }
    let held = try String.fetchAll(
      db,
      sql: """
      SELECT g.id FROM groups g
        WHERE g.removed_at IS NULL AND EXISTS (
          SELECT 1 FROM group_roles r WHERE r.grp = g.id AND r.account_id = ? AND r.role = 'admin'
        )
      """,
      arguments: [account.rawValue],
    )
    let spaceAdmin = try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM accounts a WHERE a.id = ? AND EXISTS (\(spaceAdminSQL(account: "a.id"))))",
      arguments: [account.rawValue],
    ) ?? false
    guard spaceAdmin else { return held }
    return held + (try String.fetchAll(db, sql: "SELECT id FROM groups WHERE removed_at IS NULL AND personal_account IS NULL"))
  }

  static func isHumanAdmin(_ account: AccountID, of group: GroupID, in db: Database) throws -> Bool {
    guard try Bool.fetchOne(
      db, sql: "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ? AND kind = 'human' AND removed_at IS NULL)",
      arguments: [account.rawValue],
    ) == true else { return false }
    return try Bool.fetchOne(
      db,
      sql: """
      SELECT EXISTS (SELECT 1 FROM group_roles WHERE grp = ? AND account_id = ? AND role = 'admin')
        OR (EXISTS (\(spaceAdminSQL(account: "?")))
          AND NOT EXISTS (SELECT 1 FROM groups WHERE id = ? AND personal_account IS NOT NULL))
      """,
      arguments: [group.rawValue, account.rawValue, account.rawValue, group.rawValue],
    ) ?? false
  }

  /// Writes `account`'s `role` in `group`, idempotently.
  static func grant(_ role: GroupRole, in group: GroupID, to account: AccountID, created: String, in db: Database) throws {
    try db.execute(
      sql: "INSERT OR IGNORE INTO group_roles (grp, account_id, role, created_at) VALUES (?, ?, ?, ?)",
      arguments: [group.rawValue, account.rawValue, role.rawValue, created],
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
    try db.execute(
      sql: "INSERT OR IGNORE INTO group_members (grp, account_id, joined_at) VALUES (?, ?, ?)",
      arguments: [group.rawValue, account.rawValue, created],
    )
    try grant(.admin, in: group, to: account, created: created, in: db)
    try recompute(in: db)
    return group
  }

  /// The persona allocation drawn for a human account before it adopted a persona.
  static func reservedPersona(of account: AccountID, in db: Database) throws -> (id: Int64, name: String)? {
    guard let id = try Int64.fetchOne(
      db,
      sql: """
      SELECT id FROM allocations
      WHERE kind = 'persona' AND created_by = ? AND id NOT IN (SELECT allocation FROM personas)
      ORDER BY id LIMIT 1
      """,
      arguments: [account.rawValue],
    ), let name = try Allocations.name(of: id, in: db) else { return nil }
    return (id, name)
  }

  static func insertReadEdge(src: GroupID, dst: GroupID, created: String, by creator: String?, in db: Database) throws {
    guard try !isPersonal(dst, in: db) else { throw SpaceError.personalGroupPrivate(dst.rawValue) }
    try db.execute(
      sql: "INSERT OR IGNORE INTO group_edges (src, dst, kind, created_at, created_by) VALUES (?, ?, 'read', ?, ?)",
      arguments: [src.rawValue, dst.rawValue, created, creator],
    )
  }

  static func removeReadEdge(src: GroupID, dst: GroupID, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM group_edges WHERE src = ? AND dst = ? AND kind = 'read'",
      arguments: [src.rawValue, dst.rawValue],
    )
  }

  /// Rebuilds `group_reads` from the read edges and bumps the epoch. `via` names the first hop.
  static func recompute(in db: Database) throws {
    let groups = try String.fetchAll(db, sql: "SELECT id FROM groups ORDER BY id")
    var edges: [String: [String]] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT src, dst FROM group_edges WHERE kind = 'read' ORDER BY src, dst") {
      edges[row["src"], default: []].append(row["dst"])
    }
    try db.execute(sql: "DELETE FROM group_reads")
    for group in groups {
      try db.execute(
        sql: "INSERT INTO group_reads (grp, readable, via) VALUES (?, ?, 'self')", arguments: [group, group],
      )
      for hop in edges[group, default: []] {
        var seen: Set<String> = [hop]
        var queue = [hop]
        while let next = queue.popLast() {
          if next != group {
            try db.execute(
              sql: "INSERT OR IGNORE INTO group_reads (grp, readable, via) VALUES (?, ?, ?)",
              arguments: [group, next, "\(group)->\(hop)"],
            )
          }
          for further in edges[next, default: []] where seen.insert(further).inserted {
            queue.append(further)
          }
        }
      }
    }
    try db.execute(sql: "UPDATE group_epoch SET n = n + 1 WHERE id = 1")
  }
}
