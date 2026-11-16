import GroupContract
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

extension GroupCell: SettingsReading {
  public func isSpaceAdmin(account: String) -> Bool {
    !db.rows(GroupRoleRow.where { $0.grp.eq(id.key) && $0.accountID.eq(account) && $0.role.eq(GroupRole.admin.rawValue) }).isEmpty
  }
}

func provideGroupCells(in worker: Worker) {
  worker.provide(GroupCells(settings: { $0.cell(GroupCell.ID(GroupID.settings.rawValue)) }))
}
