import GroupContract
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import Wuwei

extension GroupCell: SettingsReading {
  public func isSpaceAdmin(account: AccountID) -> Bool {
    rows.isSpaceAdmin(account.rawValue)
  }
}

func provideGroupCells(in worker: Worker) {
  worker.provide(GroupCells(settings: { $0.cell(GroupCell.ID(GroupID.settings.rawValue)) }))
}
