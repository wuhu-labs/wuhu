import GRDB
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

/// What a role lets its holder do, in order: an admin writes and reads.
public enum GroupRole: String, Hashable, Codable, Sendable, CaseIterable, Comparable {
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
public enum GroupVisibility: String, Hashable, Codable, Sendable {
  case open
  case `private`
}

/// A switch between the owner group alone and everyone who can reach it.
public enum ReachScope: String, Hashable, Codable, Sendable {
  case owner
  case reachable
}

/// One entry of a group's list: an account or another group, held at a role.
public struct GroupGrant: Hashable, Sendable {
  public enum Subject: String, Hashable, Codable, Sendable {
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

    init(groups: [GroupRow], roles: [GroupRoleRow]) {
      self.groups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
      self.roles = roles
    }

    init(_ db: Database) throws {
      try self.init(groups: GroupRow.all.fetchAll(db), roles: GroupRoleRow.all.fetchAll(db))
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
      let explicit = roleRow(account: nil, group: source, grp: group)
      guard target.visibility == GroupVisibility.open.rawValue else { return explicit }
      return explicit == .admin ? .admin : .write
    }

    /// What an account may do in a group acting out of `acting`.
    func role(of account: GroupAccountRow, in group: String, acting: String) -> GroupRole? {
      guard let target = live(group) else { return nil }
      let human = account.kind == "human" && account.removedAt == nil
      if group == GroupID.settings.rawValue { return isSpaceAdmin(account.id) ? .admin : (human ? .read : nil) }
      guard human else { return nil }
      var held = roleRow(account: account.id, group: nil, grp: group)
      if isSpaceAdmin(account.id) { held = .admin }
      guard !account.guest else { return held }
      if target.visibility == GroupVisibility.open.rawValue { held = max(held ?? .write, .write) }
      return [held, entry(from: acting, in: group)].compactMap { $0 }.max()
    }

    /// What a page may do in a group: its own group's role, minus admin.
    func role(of page: Page, in group: String) -> GroupRole? {
      role(from: page.group.rawValue, in: group).map { min($0, .write) }
    }

    /// What a session may do in a group.
    func role(of session: GroupSessionRow, in group: String) -> GroupRole? {
      guard live(group) != nil, session.isLive else { return nil }
      if group == GroupID.settings.rawValue { return .read }
      if session.isLiveRoot, session.grp == group { return .admin }
      return role(from: session.grp, in: group)
    }

    /// What `actor` may do in `group` acting out of `acting`; nil for no access.
    func role<Failure>(of actor: Actor, in group: GroupID, acting: GroupID, rows: ActorRows<Failure>) throws(Failure) -> GroupRole? {
      switch actor {
      case .publicReader:
        return nil
      case let .observer(observer):
        // An observer writes only its own group, whatever that group may write elsewhere.
        let role = role(from: observer.group.rawValue, in: group.rawValue)
        return group == observer.group ? role : role.map { min($0, .read) }
      case let .page(page):
        return role(of: page, in: group.rawValue)
      case let .session(id):
        guard let row = try rows.session(id) else { return nil }
        return role(of: row, in: group.rawValue)
      case let .person(_, id):
        guard let row = try rows.account(id) else { return role(from: acting.rawValue, in: group.rawValue) }
        return role(of: row, in: group.rawValue, acting: acting.rawValue)
      }
    }

    /// The groups sessions acting in `group` reach: a filter over the same role.
    func reach(of group: GroupID) -> Set<GroupID> {
      Set(all.filter { role(from: group.rawValue, in: $0.rawValue) != nil })
    }

    /// Who reads, with the rows behind them looked up once.
    enum Reader {
      case reach(of: String)
      case session(GroupSessionRow?)
      case person(GroupAccountRow, acting: String)
    }

    func reader<Failure>(_ actor: Actor, acting: GroupID, rows: ActorRows<Failure>) throws(Failure) -> Reader {
      switch actor {
      case .publicReader:
        return .reach(of: GroupID.shared.rawValue)
      case let .observer(observer):
        return .reach(of: observer.group.rawValue)
      case let .page(page):
        return try reader(page.viewer.principal.actor, acting: page.group, rows: rows)
      case let .session(id):
        return try .session(rows.session(id))
      case let .person(_, account):
        guard let row = try rows.account(account) else { return .reach(of: acting.rawValue) }
        return .person(row, acting: acting.rawValue)
      }
    }

    /// Whether `reader` reads `group`: its acting group's reach, or its account's rows. A guest reads only what its account is listed in; the seat a person takes is one they can read.
    func reads(_ reader: Reader, _ group: String) -> Bool {
      switch reader {
      case let .reach(source): role(from: source, in: group) != nil
      case let .session(row): row.flatMap { role(of: $0, in: group) } != nil
      case let .person(row, acting): group == acting || role(of: row, in: group, acting: acting) != nil
      }
    }

    /// The groups `actor` reads: a filter over `reads`.
    func readable<Failure>(by actor: Actor, acting: GroupID, rows: ActorRows<Failure>) throws(Failure) -> Set<GroupID> {
      let reader = try reader(actor, acting: acting, rows: rows)
      var readable = Set(all.filter { reads(reader, $0.rawValue) })
      if case let .person(_, acting) = reader { readable.insert(GroupID(rawValue: acting)) }
      return readable
    }

    /// The groups `actor` may write: its role in each is write or admin.
    func writable<Failure>(by actor: Actor, acting: GroupID, rows: ActorRows<Failure>) throws(Failure) -> Set<GroupID> {
      func writes(_ role: GroupRole?) -> Bool { (role ?? .read) >= .write }
      switch actor {
      case .publicReader:
        return []
      case let .observer(observer):
        return writes(role(from: observer.group.rawValue, in: observer.group.rawValue)) ? [observer.group] : []
      case let .page(page):
        return Set(all.filter { writes(role(of: page, in: $0.rawValue)) })
      case let .session(id):
        guard let session = try rows.session(id) else { return [] }
        return Set(all.filter { writes(role(of: session, in: $0.rawValue)) })
      case let .person(_, account):
        guard let row = try rows.account(account) else { return [] }
        return Set(all.filter { writes(role(of: row, in: $0.rawValue, acting: acting.rawValue)) })
      }
    }

    func administered<Failure>(by actor: Actor, rows: ActorRows<Failure>) throws(Failure) -> Set<GroupID> {
      switch actor {
      case .publicReader, .observer, .page:
        return []
      case let .session(id):
        return try rows.session(id).map(administered(by:)) ?? []
      case let .person(_, account):
        return try rows.account(account).map(administered(by:)) ?? []
      }
    }

    func isSpaceAdmin(_ account: String) -> Bool {
      roles.contains { $0.accountID == account && $0.grp == GroupID.settings.rawValue && $0.role == GroupRole.admin.rawValue }
    }

    /// The direct human admin of a group: an account row, never one inherited
    /// through an acting group. Space admins administer every group.
    func isHumanAdmin(_ account: GroupAccountRow, of group: String) -> Bool {
      guard account.kind == "human", account.removedAt == nil, live(group) != nil else { return false }
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

  /// How a rule finds the row of the session or the account an actor names.
  struct ActorRows<Failure: Error> {
    let session: (SessionID) throws(Failure) -> GroupSessionRow?
    let account: (AccountID) throws(Failure) -> GroupAccountRow?
  }

  static func actorRows(in db: Database) -> ActorRows<any Error> {
    ActorRows(session: { try sessionRow($0, in: db) }, account: { try accountRow($0, in: db) })
  }

  static func role(of actor: Actor, in group: GroupID, acting: GroupID, in db: Database) throws -> GroupRole? {
    try Snapshot(db).role(of: actor, in: group, acting: acting, rows: actorRows(in: db))
  }

  static func readable(by actor: Actor, acting: GroupID, in db: Database) throws -> Set<GroupID> {
    try Snapshot(db).readable(by: actor, acting: acting, rows: actorRows(in: db))
  }

  static func isLiveHuman(_ account: AccountID, in db: Database) throws -> Bool {
    guard let row = try accountRow(account, in: db) else { return false }
    return row.kind == "human" && row.removedAt == nil
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
}
