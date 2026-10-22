import GRDB
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

/// What a role lets its holder do, in order: an admin writes and reads.
public enum GroupRole: String, Hashable, Sendable, CaseIterable, Comparable {
  case read
  case write
  case admin

  private var rank: Int {
    switch self {
    case .read: 0
    case .write: 1
    case .admin: 2
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Whether a group takes everyone in, or only the entries its list names.
public enum GroupVisibility: String, Hashable, Sendable {
  case open
  case `private`
}

/// A switch between the owner group alone and everyone who can reach it.
public enum ReachScope: String, Hashable, Sendable {
  case owner
  case reachable
}

/// One entry of a group's list: an account or another group, held at a role.
public struct GroupGrant: Hashable, Sendable {
  public enum Subject: String, Hashable, Sendable {
    case account
    case group
  }

  public let subject: Subject
  public let id: String
  public let role: GroupRole
}

/// The one access rule: a role names what a subject may do in a group, and
/// every reach is a filter over that role.
enum GroupAccess {
  /// The groups, their lists and the roles, read once.
  struct Snapshot {
    let groups: [String: GroupRow]
    let roles: [GroupRoleRow]

    init(_ db: Database) throws {
      groups = Dictionary(uniqueKeysWithValues: try GroupRow.all.fetchAll(db).map { ($0.id, $0) })
      roles = try GroupRoleRow.all.fetchAll(db)
    }

    func live(_ group: String) -> GroupRow? {
      guard let row = groups[group], row.removedAt == nil else { return nil }
      return row
    }

    var all: [GroupID] {
      groups.values.filter { $0.removedAt == nil }.map { GroupID(rawValue: $0.id) }
    }

    /// The role a group holds in a target: itself, the settings group, an open
    /// group, or its own row.
    func role(from source: String, in group: String) -> GroupRole? {
      guard let target = live(group) else { return nil }
      if group == GroupID.settings.rawValue { return .read }
      if source == group { return .write }
      guard target.personalAccount == nil else { return nil }
      let explicit = roleRow(account: nil, group: source, grp: group)
      guard target.visibility == GroupVisibility.open.rawValue else { return explicit }
      return explicit == .admin ? .admin : .write
    }

    /// What an account may do in a group acting out of `acting`.
    func role(of account: GroupAccountRow, in group: String, acting: String) -> GroupRole? {
      guard let target = live(group) else { return nil }
      if let owner = target.personalAccount { return owner == account.id ? .admin : nil }
      let human = account.kind == "human" && account.removedAt == nil
      if group == GroupID.settings.rawValue { return isSpaceAdmin(account.id) ? .admin : (human ? .read : nil) }
      guard human else { return nil }
      var held = roleRow(account: account.id, group: nil, grp: group)
      if isSpaceAdmin(account.id) { held = .admin }
      guard !account.guest else { return held }
      if target.visibility == GroupVisibility.open.rawValue { held = max(held ?? .write, .write) }
      return [held, entry(from: acting, in: group)].compactMap { $0 }.max()
    }

    /// What a session may do in a group.
    func role(of session: GroupSessionRow, in group: String) -> GroupRole? {
      guard live(group) != nil, session.isLive else { return nil }
      if group == GroupID.settings.rawValue { return .read }
      if session.isLiveRoot, session.grp == group { return .admin }
      return role(from: session.grp, in: group)
    }

    func isSpaceAdmin(_ account: String) -> Bool {
      roles.contains { $0.accountID == account && $0.grp == GroupID.settings.rawValue && $0.role == GroupRole.admin.rawValue }
    }

    /// The direct human admin of a group: an account row, never one inherited
    /// through an acting group. Space admins administer every group but another
    /// person's own.
    func isHumanAdmin(_ account: GroupAccountRow, of group: String) -> Bool {
      guard account.kind == "human", account.removedAt == nil, let target = live(group) else { return false }
      if let owner = target.personalAccount { return owner == account.id }
      if isSpaceAdmin(account.id) { return true }
      return roleRow(account: account.id, group: nil, grp: group) == .admin
    }

    func administered(by account: GroupAccountRow) -> Set<GroupID> {
      Set(all.filter { isHumanAdmin(account, of: $0.rawValue) })
    }

    func administered(by session: GroupSessionRow) -> Set<GroupID> {
      guard session.isLive else { return [] }
      var administered = Set(roles.filter {
        $0.sourceGroup == session.grp && $0.role == GroupRole.admin.rawValue && $0.grp != GroupID.settings.rawValue
      }.map { GroupID(rawValue: $0.grp) })
      if session.isLiveRoot { administered.insert(GroupID(rawValue: session.grp)) }
      return administered
    }

    func grants(of group: String) -> [GroupGrant] {
      roles.filter { $0.grp == group }.compactMap { row in
        guard let role = GroupRole(rawValue: row.role) else { return nil }
        if let account = row.accountID { return GroupGrant(subject: .account, id: account, role: role) }
        if let source = row.sourceGroup { return GroupGrant(subject: .group, id: source, role: role) }
        return nil
      }.sorted { ($0.subject.rawValue, $0.id) < ($1.subject.rawValue, $1.id) }
    }

    /// The explicit row a group holds in a target, with no open or self rule.
    func entry(from source: String, in group: String) -> GroupRole? {
      roleRow(account: nil, group: source, grp: group)
    }

    private func roleRow(account: String?, group: String?, grp: String) -> GroupRole? {
      let row = roles.first { candidate in
        guard candidate.grp == grp else { return false }
        if let account { return candidate.accountID == account && candidate.sourceGroup == nil }
        return candidate.accountID == nil && candidate.sourceGroup == group
      }
      return row.flatMap { GroupRole(rawValue: $0.role) }
    }
  }

  static func accountRow(_ id: AccountID, in db: Database) throws -> GroupAccountRow? {
    try GroupAccountRow.where { $0.id.eq(id.rawValue) }.fetchOne(db)
  }

  static func sessionRow(_ id: SessionID, in db: Database) throws -> GroupSessionRow? {
    try GroupSessionRow.where { $0.id.eq(id.rawValue) }.fetchOne(db)
  }

  /// What `actor` may do in `group` acting out of `acting`; nil for no access.
  /// The --dev seat is the caller's to admit, and gets no role here.
  static func role(of actor: Actor, in group: GroupID, acting: GroupID, in db: Database) throws -> GroupRole? {
    let snapshot = try Snapshot(db)
    switch actor {
    case .anonymous:
      return nil
    case let .session(id):
      guard let session = try sessionRow(id, in: db) else { return nil }
      return snapshot.role(of: session, in: group.rawValue)
    case let .person(_, account):
      guard let row = try accountRow(account, in: db) else {
        return snapshot.role(from: acting.rawValue, in: group.rawValue)
      }
      return snapshot.role(of: row, in: group.rawValue, acting: acting.rawValue)
    }
  }

  /// The groups sessions acting in `group` reach: a filter over the same role.
  static func reach(of group: GroupID, in db: Database) throws -> Set<GroupID> {
    let snapshot = try Snapshot(db)
    return Set(snapshot.all.filter { snapshot.role(from: group.rawValue, in: $0.rawValue) != nil })
  }

  /// The groups `actor` reads: its acting group's reach, plus its account's
  /// rows. A guest reads only what its account is listed in.
  static func readable(by actor: Actor, acting: GroupID, in db: Database) throws -> Set<GroupID> {
    let snapshot = try Snapshot(db)
    switch actor {
    case .anonymous:
      return try reach(of: acting, in: db)
    case let .session(id):
      guard let session = try sessionRow(id, in: db) else { return [] }
      return Set(snapshot.all.filter { snapshot.role(of: session, in: $0.rawValue) != nil })
    case let .person(_, account):
      guard let row = try accountRow(account, in: db) else { return try reach(of: acting, in: db) }
      // The seat a person takes is one they can read; their rows decide the rest.
      var readable = Set(snapshot.all.filter { snapshot.role(of: row, in: $0.rawValue, acting: acting.rawValue) != nil })
      readable.insert(acting)
      return readable
    }
  }

  static func isHumanAdmin(_ account: AccountID, of group: GroupID, in db: Database) throws -> Bool {
    guard let row = try accountRow(account, in: db) else { return false }
    return try Snapshot(db).isHumanAdmin(row, of: group.rawValue)
  }

  static func writes(_ group: GroupID, in target: GroupID, in db: Database) throws -> Bool {
    try (Snapshot(db).role(from: group.rawValue, in: target.rawValue) ?? .read) >= .write
  }

  static func isLiveHuman(_ account: AccountID, in db: Database) throws -> Bool {
    guard let row = try accountRow(account, in: db) else { return false }
    return row.kind == "human" && row.removedAt == nil
  }

  static func isGuest(_ account: AccountID, in db: Database) throws -> Bool {
    try accountRow(account, in: db)?.guest ?? false
  }

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

  static func isSpaceAdmin(_ account: AccountID, in db: Database) throws -> Bool {
    guard try isLiveHuman(account, in: db) else { return false }
    return try Bool.fetchOne(
      db, sql: "SELECT EXISTS (\(spaceAdminSQL(account: "?")))", arguments: [account.rawValue],
    ) ?? false
  }

  static func requireAdmin(_ actor: Actor, of group: GroupID, acting: GroupID, in db: Database) throws {
    if case .anonymous = actor { return }
    guard try role(of: actor, in: group, acting: acting, in: db) == .admin else {
      throw SpaceError.groupForbidden(group.rawValue)
    }
  }
}
