#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import GRDB
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

let groupSchemaSQL = """
CREATE TABLE IF NOT EXISTS "schema_compactions" (
  "name" TEXT NOT NULL PRIMARY KEY,
  "applied_at" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "group_epoch" (
  "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
  "n" INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS "groups" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "created_at" TEXT NOT NULL,
  "space_layer" INTEGER NOT NULL DEFAULT 1 CHECK ("space_layer" IN (0, 1)),
  "removed_at" TEXT
);
CREATE TABLE IF NOT EXISTS "group_members" (
  "grp" TEXT NOT NULL REFERENCES "groups" ("id"),
  "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
  "joined_at" TEXT NOT NULL,
  PRIMARY KEY ("grp", "account_id")
);
CREATE INDEX IF NOT EXISTS "group_members_by_account" ON "group_members" ("account_id");
CREATE TABLE IF NOT EXISTS "group_edges" (
  "src" TEXT NOT NULL REFERENCES "groups" ("id"),
  "dst" TEXT NOT NULL REFERENCES "groups" ("id"),
  "kind" TEXT NOT NULL CHECK ("kind" IN ('read', 'admin')),
  "created_at" TEXT NOT NULL,
  "created_by" TEXT,
  PRIMARY KEY ("src", "dst", "kind")
);
CREATE TABLE IF NOT EXISTS "message_groups" (
  "message_id" TEXT NOT NULL PRIMARY KEY,
  "grp" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "session_space_layer" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "space_layer" INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS "group_reads" (
  "grp" TEXT NOT NULL,
  "readable" TEXT NOT NULL,
  "via" TEXT NOT NULL,
  PRIMARY KEY ("grp", "readable", "via")
);
INSERT OR IGNORE INTO "schema_compactions" ("name", "applied_at") VALUES ('wuhu-45', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
INSERT OR IGNORE INTO "group_epoch" ("id", "n") VALUES (1, 1);
INSERT OR IGNORE INTO "groups" ("id", "created_at") VALUES ('shared', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
INSERT OR IGNORE INTO "group_reads" ("grp", "readable", "via") VALUES ('shared', 'shared', 'self');
"""

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
  public let spaceLayer: Bool
  public let removedAt: Date?
}

public enum GroupEdgeKind: String, Sendable {
  case read
  case admin
}

extension Space {
  public func groups() async throws -> [GroupRecord] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: "SELECT id, created_at, space_layer, removed_at FROM groups ORDER BY created_at, id").map { row in
        GroupRecord(
          id: GroupID(rawValue: row["id"]),
          createdAt: (try? SQLiteDateFormat.date(from: row["created_at"])) ?? Date(timeIntervalSince1970: 0),
          spaceLayer: row["space_layer"],
          removedAt: (row["removed_at"] as String?).flatMap { try? SQLiteDateFormat.date(from: $0) },
        )
      }
    }
  }

  /// The groups `group` reads, itself included.
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
    try await writer.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM group_members WHERE grp = ? AND account_id = ?)",
        arguments: [group.rawValue, account.rawValue],
      ) ?? false
    }
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

  /// Top-level agents (kind agent, no parent, live) in `group`, plus human admins of `group`.
  public func isAdmin(_ actor: Actor, of group: GroupID) async throws -> Bool {
    try await writer.read { db in try Groups.isAdmin(actor, of: group, in: db) }
  }

  /// A live human with a membership in a self-administering group that holds
  /// an admin edge to `group`: the rule `is_admin` and last-admin counting use.
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

  public func addEdge(src: GroupID, dst: GroupID, kind: GroupEdgeKind, by creator: String?) async throws {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try Groups.addEdge(src: src, dst: dst, kind: kind, created: created, by: creator, in: db)
    }
  }

  public func removeEdge(src: GroupID, dst: GroupID, kind: GroupEdgeKind) async throws {
    try await writer.write { db in
      try Groups.removeEdge(src: src, dst: dst, kind: kind, in: db)
    }
  }
}

enum Groups {
  /// The account's personal group: the group it is a member of that administers itself.
  static let personalGroupSQL: String = """
  SELECT m.grp FROM group_members m
  JOIN group_edges s ON s.src = m.grp AND s.dst = m.grp AND s.kind = 'admin'
  WHERE m.account_id = ? ORDER BY m.joined_at, m.grp LIMIT 1
  """

  /// The one rule for a person administering a group: a membership of theirs
  /// in a self-administering group (their personal group or a team's) that
  /// holds an admin edge to it. `account` and `group` are SQL expressions.
  static func adminMembershipSQL(account: String, group: String) -> String {
    """
    SELECT 1 FROM group_members m
      JOIN group_edges s ON s.src = m.grp AND s.dst = m.grp AND s.kind = 'admin'
      JOIN group_edges e ON e.src = m.grp AND e.dst = \(group) AND e.kind = 'admin'
      WHERE m.account_id = \(account)
    """
  }

  /// The groups whose membership makes `account` an admin of `group`.
  static func adminGrantingGroups(of account: AccountID, over group: GroupID, in db: Database) throws -> [GroupID] {
    try String.fetchAll(
      db,
      sql: """
      SELECT DISTINCT m.grp FROM group_members m
        JOIN group_edges s ON s.src = m.grp AND s.dst = m.grp AND s.kind = 'admin'
        JOIN group_edges e ON e.src = m.grp AND e.dst = ? AND e.kind = 'admin'
        WHERE m.account_id = ? ORDER BY m.grp
      """,
      arguments: [group.rawValue, account.rawValue],
    ).map(GroupID.init(rawValue:))
  }

  /// `is_admin` of an `accounts` row: a human admin of shared.
  static let sharedAdminColumn: String =
    "EXISTS (\(adminMembershipSQL(account: "accounts.id", group: "'shared'")) AND accounts.kind = 'human') AS is_admin"

  static func reads(_ group: GroupID, in db: Database) throws -> Set<GroupID> {
    let readable = try String.fetchAll(db, sql: "SELECT readable FROM group_reads WHERE grp = ?", arguments: [group.rawValue])
    return Set(readable.map(GroupID.init(rawValue:))).union([group])
  }

  static func personalGroup(of account: AccountID, in db: Database) throws -> GroupID? {
    try String.fetchOne(db, sql: personalGroupSQL, arguments: [account.rawValue]).map(GroupID.init(rawValue:))
  }

  static func isAdmin(_ actor: Actor, of group: GroupID, in db: Database) throws -> Bool {
    switch actor {
    case let .session(id):
      try Bool.fetchOne(
        db,
        sql: """
        SELECT EXISTS (SELECT 1 FROM sessions
          WHERE id = ? AND grp = ? AND kind = 'agent' AND parent IS NULL AND lifecycle = 'live')
        """,
        arguments: [id.rawValue, group.rawValue],
      ) ?? false
    case let .person(_, account):
      try isHumanAdmin(account, of: group, in: db)
    case .anonymous:
      false
    }
  }

  static func isHumanAdmin(_ account: AccountID, of group: GroupID, in db: Database) throws -> Bool {
    guard try Bool.fetchOne(
      db, sql: "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ? AND kind = 'human' AND removed_at IS NULL)",
      arguments: [account.rawValue],
    ) == true else { return false }
    return try Bool.fetchOne(
      db, sql: "SELECT EXISTS (\(adminMembershipSQL(account: "?", group: "?")))",
      arguments: [group.rawValue, account.rawValue],
    ) ?? false
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
    try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, ?)", arguments: [name, created])
    for member in [group, .shared] {
      try db.execute(
        sql: "INSERT OR IGNORE INTO group_members (grp, account_id, joined_at) VALUES (?, ?, ?)",
        arguments: [member.rawValue, account.rawValue, created],
      )
    }
    try insertEdge(src: group, dst: .shared, kind: .read, created: created, by: nil, in: db)
    try insertEdge(src: group, dst: group, kind: .admin, created: created, by: nil, in: db)
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

  static func addEdge(src: GroupID, dst: GroupID, kind: GroupEdgeKind, created: String, by creator: String?, in db: Database) throws {
    try insertEdge(src: src, dst: dst, kind: kind, created: created, by: creator, in: db)
    try recompute(in: db)
  }

  static func removeEdge(src: GroupID, dst: GroupID, kind: GroupEdgeKind, in db: Database) throws {
    if kind == .admin, src == dst {
      throw SpaceError.personalGroupEdge(src.rawValue)
    }
    let admins = kind == .admin ? try humanAdminCount(of: dst, in: db) : 0
    try db.execute(
      sql: "DELETE FROM group_edges WHERE src = ? AND dst = ? AND kind = ?",
      arguments: [src.rawValue, dst.rawValue, kind.rawValue],
    )
    if admins > 0, try humanAdminCount(of: dst, in: db) == 0 {
      throw SpaceError.lastAdmin(src.rawValue)
    }
    try recompute(in: db)
  }

  /// Live people who administer `group`, by `adminMembershipSQL`.
  static func humanAdminCount(of group: GroupID, in db: Database) throws -> Int {
    try Int.fetchOne(
      db,
      sql: """
      SELECT count(*) FROM accounts a
      WHERE a.kind = 'human' AND a.removed_at IS NULL AND EXISTS (\(adminMembershipSQL(account: "a.id", group: "?")))
      """,
      arguments: [group.rawValue],
    ) ?? 0
  }

  private static func insertEdge(
    src: GroupID, dst: GroupID, kind: GroupEdgeKind, created: String, by creator: String?, in db: Database,
  ) throws {
    try db.execute(
      sql: "INSERT OR IGNORE INTO group_edges (src, dst, kind, created_at, created_by) VALUES (?, ?, ?, ?, ?)",
      arguments: [src.rawValue, dst.rawValue, kind.rawValue, created, creator],
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
