import AgentsContract
import GroupContract
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import Wuwei

extension GroupCell: GroupReading, SettingsReading {
  public func isSpaceAdmin(account: AccountID) -> Bool {
    rows.isSpaceAdmin(account.rawValue)
  }

  public func role(ofSession id: SessionID) -> GroupRole? {
    guard let summary = ctx.session(id).summary else { return nil }
    let lifecycle: String = switch summary.lifecycle {
    case .live: "live"
    case let .archived(_): "archived"
    }
    return rows.role(
      of: GroupSessionRow(
        id: summary.id.rawValue, grp: summary.group.rawValue, kind: summary.kind.rawValue,
        parent: summary.parent?.rawValue, lifecycle: lifecycle,
      ),
      in: self.id.key,
    )
  }

  public func role(ofAccount id: AccountID, acting: GroupID) -> GroupRole? {
    GroupAccess.ActorRows(ctx).account(id).flatMap { rows.role(of: $0, in: self.id.key, acting: acting.rawValue) }
  }

  public func role(ofGroup group: GroupID) -> GroupRole? {
    rows.role(from: group.rawValue, in: id.key)
  }

  public func exists() -> Bool {
    rows.live(id.key) != nil
  }
}

func provideGroupCells(in worker: Worker) {
  worker.provide(GroupCells(
    settings: { $0.cell(GroupCell.ID(GroupID.settings.rawValue)) },
    group: { reading, id in reading.cell(GroupCell.ID(id.rawValue)) },
  ))
}
