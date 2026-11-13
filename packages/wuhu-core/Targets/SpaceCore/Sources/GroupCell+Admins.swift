import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

extension GroupCell {
  mutating func setAdmin(_ account: AccountID, admin: Bool, at stamp: String) throws -> Bool {
    precondition(id.key == GroupID.settings.rawValue)
    let grants = db.rows(GroupRoleRow.where { $0.grp.eq(id.key) && $0.role.eq(GroupRole.admin.rawValue) })
    let held = grants.contains { $0.accountID == account.rawValue }
    if held, !admin {
      let live = grants.filter { grant in
        guard let id = grant.accountID else { return false }
        let row = ctx.cell(PersonCell.ID(id)).account()!
        return row.removedAt == nil && row.kind == .human && !row.guest
      }
      if live.count == 1 { throw SpaceError.lastAdmin(account.rawValue) }
    }
    if admin, !held {
      try db.execute(GroupRoleRow.where { $0.grp.eq(id.key) && $0.accountID.eq(account.rawValue) }.delete())
      try db.execute(GroupRoleRow.insert { GroupRoleRow(accountID: account.rawValue, sourceGroup: nil, grp: id.key, role: GroupRole.admin.rawValue, createdAt: stamp) })
    } else if !admin {
      try db.execute(GroupRoleRow.where { $0.grp.eq(id.key) && $0.accountID.eq(account.rawValue) && $0.role.eq(GroupRole.admin.rawValue) }.delete())
    }
    return admin
  }
}
