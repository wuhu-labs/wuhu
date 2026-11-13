#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import struct SpaceContract.GroupID
import SpaceFS

extension Space {
  public func deleteMachine(_ id: MachineID, by principal: Principal) async throws {
    let record = try worker.read { reader in
      guard let record = reader.cell(MachineCell.ID(id.rawValue)).record(), reader.cell(SpaceCell.ID("space")).machineV2Member(id) else {
        throw SpaceError.notFound(id.rawValue)
      }
      return record
    }
    let group = record.group
    switch principal.actor {
    case let .person(_, account):
      guard worker.cell(GroupCell.ID(group.rawValue)).isHumanAdmin(account) else { throw SpaceError.groupForbidden(group.rawValue) }
    case .session, .observer, .page, .publicReader: throw SpaceError.groupForbidden(group.rawValue)
    }
    // The machine's row cannot go while a device names it: each owner lets its own go first, and a link that appears
    // in between fails the deletion call below, which the caller repeats.
    let accounts = cell.deviceAccounts(machine: id)
    for account in accounts {
      _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.detachMachine(id) }
    }
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.delete(in: group) }
  }
}
