import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

/// A group, keyed by its id. Formal for now: it owns no table and takes no mail, and its reads load the rows `GroupAccess` rules over, which stay main's to write until their owner flips.
@Cell
public struct GroupCell {
  /// What `actor` may do here acting out of `acting`; nil for no access.
  public func role(of actor: Actor, acting: GroupID) -> GroupRole? {
    rows.role(of: actor, in: GroupID(rawValue: id.key), acting: acting, rows: GroupAccess.ActorRows(db))
  }

  /// Whether the person behind `account` administers the group: its owner, a space admin, or an admin on its list.
  public func isHumanAdmin(_ account: AccountID) -> Bool {
    GroupAccess.ActorRows(db).account(account).map { rows.isHumanAdmin($0, of: id.key) } ?? false
  }

  /// The group's list, whoever asks: `role` says who may see it.
  public func grants() -> [GroupGrant] {
    rows.grants(of: id.key)
  }

  /// Nil for a group that was removed or never made.
  public func record() -> GroupRecord? {
    rows.live(id.key).map(GroupRecord.init(row:))
  }

  /// This group's row and list, and the settings group's list, which names the space admins.
  private var rows: GroupAccess.Snapshot {
    GroupAccess.Snapshot(
      groups: db.rows(GroupRow.where { $0.id.eq(id.key) }),
      roles: db.rows(GroupRoleRow.where { $0.grp.in([id.key, GroupID.settings.rawValue]) }),
    )
  }
}

/// The space, under the one key `space`: what spans its groups. Formal as `GroupCell` is, over the same rows and rules.
@Cell
public struct SpaceCell {
  /// Every group, removed ones too, oldest first.
  public func groups() -> [GroupRecord] {
    db.rows(GroupRow.order { ($0.createdAt, $0.id) }).map(GroupRecord.init(row:))
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

  /// The person a spelling names: by alias, persona name or profile; nil for nobody.
  func person(_ spelling: String) -> String? {
    let name = alias(ofPerson: spelling) ?? spelling
    if !db.rows(PersonaRow.where { $0.name.eq(name) }).isEmpty { return name }
    return db.rows(UserProfileRow.where { $0.principal.eq(name) }).first?.principal
  }

  func alias(ofPerson spelling: String) -> String? {
    db.rows(AliasRow.where { $0.name.eq(spelling.lowercased()) && $0.kind.eq(AliasKind.person) }).first?.target
  }

  private var rows: GroupAccess.Snapshot {
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
