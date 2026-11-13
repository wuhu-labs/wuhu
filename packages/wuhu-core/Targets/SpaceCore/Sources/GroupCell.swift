import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

/// A group, keyed by its id: its `groups` row and its `group_roles` rows, which only its own steps write.
@Cell
public struct GroupCell {
  /// What `actor` may do here acting out of `acting`; nil for no access.
  public func role(of actor: Actor, acting: GroupID) -> GroupRole? {
    rows.role(of: actor, in: GroupID(rawValue: id.key), acting: acting, rows: GroupAccess.ActorRows(db))
  }

  /// Whether `principal` reads the group: the rule `SpaceCell.readable` filters every group by, which differs from `role` for the anonymous --dev seat and for a page, read with its viewer's rights.
  public func reads(_ principal: Principal) -> Bool {
    rows.reads(rows.reader(principal.actor, acting: principal.group, rows: GroupAccess.ActorRows(db)), id.key)
  }

  /// Whether the person behind `account` administers the group: its owner, a space admin, or an admin on its list.
  public func isHumanAdmin(_ account: AccountID) -> Bool {
    GroupAccess.ActorRows(db).account(account).map { rows.isHumanAdmin($0, of: id.key) } ?? false
  }

  /// Whether `group` may write here: the switch a machine's or a secret's scope reads.
  public func writes(from group: GroupID) -> Bool {
    (rows.role(from: group.rawValue, in: id.key) ?? .read) >= .write
  }

  /// Writing a group's file takes a write role in it; the --dev seat is unrestricted.
  public func refusesWrite(_ path: SpacePath, by actor: Actor, acting: GroupID) throws {
    if case .anonymous = actor { return }
    guard let held = role(of: actor, acting: acting) else { throw SpaceError.notFound(path.rawValue) }
    guard held >= .write else { throw SpaceError.forbiddenWrite(path: path.rawValue, group: id.key) }
  }

  /// The group's list, whoever asks: `role` says who may see it.
  public func grants() -> [GroupGrant] {
    rows.grants(of: id.key)
  }

  /// Makes the group if it is not there. The claim mails this and its caller calls it: both arrivals are real, and the second finds the row.
  public mutating func create(_ claim: GroupClaim) throws {
    guard db.rows(GroupRow.where { $0.id.eq(id.key) }).isEmpty else { return }
    try db.execute(GroupRow.insert {
      GroupRow(
        id: id.key, createdAt: claim.created, visibility: GroupVisibility.open.rawValue, secretsScope: ReachScope.owner.rawValue,
        name: claim.name,
      )
    })
    try db.execute(GroupRoleRow.insert {
      GroupRoleRow(
        accountID: claim.owner.rawValue, sourceGroup: nil, grp: id.key, role: GroupRole.admin.rawValue, createdAt: claim.created,
      )
    })
  }

  /// Nil for a group that was removed or never made.
  public func record() -> GroupRecord? {
    rows.live(id.key).map { GroupRecord(row: $0, alias: alias) }
  }

  /// This group's row and list, and the settings group's list, which names the space admins.
  var rows: GroupAccess.Snapshot {
    GroupAccess.Snapshot(
      groups: db.rows(GroupRow.where { $0.id.eq(id.key) }),
      roles: db.rows(GroupRoleRow.where { $0.grp.in([id.key, GroupID.settings.rawValue]) }),
    )
  }

  private var alias: String? {
    db.rows(AliasRow.where { $0.kind.eq(AliasKind.group) && $0.target.eq(id.key) && $0.current }).first?.name
  }
}

/// The space, under the one key `space`: what spans its groups.
@Cell
public struct SpaceCell {
  /// Every group, removed ones too, oldest first.
  public func groups() -> [GroupRecord] {
    let aliases = Dictionary(
      uniqueKeysWithValues: db.rows(AliasRow.where { $0.kind.eq(AliasKind.group) && $0.current }).map { ($0.target, $0.name) },
    )
    return db.rows(GroupRow.order { ($0.createdAt, $0.id) }).map { GroupRecord(row: $0, alias: aliases[$0.id]) }
  }

  /// The groups `group` reads by its own entries, itself included.
  public func reach(of group: GroupID) -> Set<GroupID> {
    rows.reach(of: group)
  }

  public func readable(by principal: Principal) -> Set<GroupID> {
    rows.readable(by: principal.actor, acting: principal.group, rows: GroupAccess.ActorRows(db))
  }

  /// The groups `principal` may write: its role in each is write or admin.
  public func writable(by principal: Principal) -> Set<GroupID> {
    rows.writable(by: principal.actor, acting: principal.group, rows: GroupAccess.ActorRows(db))
  }

  /// Every group `principal` administers, by the rule `GroupCell.role` answers `admin` by.
  public func administered(by principal: Principal) -> Set<GroupID> {
    rows.administered(by: principal.actor, rows: GroupAccess.ActorRows(db))
  }

  /// The last reset seen of each fixed plan window, kept across restarts.
  public mutating func saveWindowResets(_ resets: [UsageWindowKey: Double]) throws {
    for (key, resetsAt) in resets {
      try db.execute(UsageWindowResetRow.insert {
        UsageWindowResetRow(provider: key.provider, window: key.window, resetsAt: resetsAt)
      } onConflict: {
        ($0.provider, $0.window)
      } doUpdate: {
        $0.resetsAt = $1.resetsAt
      })
    }
  }

  /// The person a spelling names: by alias, persona name or profile; nil for nobody.
  func person(_ spelling: String) -> String? { directoryTarget(spelling, sessions: false) }

  func directoryTarget(_ spelling: String, sessions: Bool) -> String? {
    db.rows(#sql("""
    WITH person(principal) AS (
      SELECT COALESCE((SELECT target FROM aliases WHERE name = \(bind: spelling.lowercased()) AND kind = 'person'), \(bind: spelling))
    )
    SELECT \(bind: spelling) WHERE \(bind: sessions) AND EXISTS (SELECT 1 FROM sessions WHERE id = \(bind: spelling))
    UNION ALL
    SELECT principal FROM person
    WHERE EXISTS (SELECT 1 FROM personas WHERE name = person.principal)
      OR EXISTS (SELECT 1 FROM aliases WHERE kind = 'person' AND current AND target = person.principal)
    LIMIT 1
    """, as: String.self)).first
  }

  func alias(ofPerson spelling: String) -> String? {
    db.rows(AliasRow.where { $0.name.eq(spelling.lowercased()) && $0.kind.eq(AliasKind.person) }).first?.target
  }

  var rows: GroupAccess.Snapshot {
    GroupAccess.Snapshot(groups: db.rows(GroupRow.all), roles: db.rows(GroupRoleRow.all))
  }
}

extension GroupAccess.ActorRows<Never> {
  init(_ db: Database) {
    self.init(
      session: { session in db.rows(GroupSessionRow.where { $0.id.eq(session.rawValue) }).first },
      account: { account in db.rows(GroupAccountRow.where { $0.id.eq(account.rawValue) }).first },
    )
  }
}

extension Space {
  public nonisolated var cell: SpaceCell {
    worker.cell(SpaceCell.ID("space"))
  }

  public nonisolated func cell(of group: GroupID) -> GroupCell {
    worker.cell(GroupCell.ID(group.rawValue))
  }
}
