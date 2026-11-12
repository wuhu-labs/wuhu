import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import StructuredQueries

extension SpaceCell {
  /// Whether `account` may own a group: a live person, not a guest.
  func canOwnGroup(_ account: AccountID) -> Bool {
    guard let row = GroupAccess.ActorRows(db).account(account) else { return false }
    return row.kind == "human" && row.removedAt == nil && !row.guest
  }

  /// The group a spelling names: an id, a current or retired alias, or a person's alias naming their own group.
  func resolve(_ spelling: String) -> GroupID? {
    if let row = db.rows(GroupRow.where { $0.id.eq(spelling) }).first, row.removedAt == nil {
      return GroupID(rawValue: row.id)
    }
    guard let alias = db.rows(AliasRow.where { $0.name.eq(spelling.lowercased()) }).first else { return nil }
    switch alias.kind {
    case .group:
      guard let row = db.rows(GroupRow.where { $0.id.eq(alias.target) }).first, row.removedAt == nil else { return nil }
      return GroupID(rawValue: row.id)
    case .person:
      guard let account = db.rows(PersonaRow.where { $0.name.eq(alias.target) }).first?.accountID else { return nil }
      return personalGroup(of: AccountID(rawValue: account))
    case .machine:
      return nil
    }
  }

  /// The groups an account is listed in, by any role.
  func memberGroups(of account: AccountID) -> Set<GroupID> {
    let live = Set(rows.all)
    return Set(
      db.rows(GroupRoleRow.where { $0.accountID.eq(account.rawValue) })
        .map { GroupID(rawValue: $0.grp) }
        .filter { live.contains($0) },
    )
  }

  func isGuest(_ account: AccountID) -> Bool {
    GroupAccess.ActorRows(db).account(account)?.guest ?? false
  }

  /// An account's own group: the one live group it owns, if it has one.
  func personalGroup(of account: AccountID) -> GroupID? {
    db.rows(GroupRow.where { $0.personalAccount.eq(account.rawValue) && $0.removedAt.is(nil) }.order { ($0.createdAt, $0.id) }.limit(1))
      .first.map { GroupID(rawValue: $0.id) }
  }

  /// The group a session acts in.
  func group(of session: SessionID) -> GroupID {
    db.rows(GroupSessionRow.where { $0.id.eq(session.rawValue) }).first.map { GroupID(rawValue: $0.grp) } ?? .shared
  }
}
