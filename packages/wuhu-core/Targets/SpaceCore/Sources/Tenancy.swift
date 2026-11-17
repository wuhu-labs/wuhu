import GroupContract
import struct MachineContract.MachineID
import SpaceFS
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import StructuredQueries
import TenancyContract
import Wuwei
import WuweiQueries

extension SpaceCell: SpaceReading {
  public func machineName(_ id: MachineID) -> String? {
    db.rows(AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.target.eq(id.rawValue) && $0.current.eq(true) }).first?.name
  }

  public func machineNames() -> [MachineID: String] {
    Dictionary(uniqueKeysWithValues: db.rows(AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.current.eq(true) }).map { (MachineID(rawValue: $0.target), $0.name) })
  }

  public func machineID(named name: String) -> MachineID? {
    let lowered = name.lowercased().replacingOccurrences(of: "-", with: "_")
    return db.rows(AliasRow.where { $0.name.eq(lowered) && $0.kind.eq(AliasKind.machine) }).first.map { MachineID(rawValue: $0.target) }
  }

  public func writableGroups(of group: GroupID) -> Set<GroupID> {
    Set(rows.all.filter { (rows.role(from: group.rawValue, in: $0.rawValue) ?? .read) >= .write })
  }
}

func provideTenancyCells(in worker: Worker) {
  worker.provide(TenancyCells(space: { $0.cell(SpaceCell.ID("space")) }))
}

extension Space {
  /// The space's side of the tenancy contract: what another family asks of its aliases, devices and groups.
  public nonisolated var tenancy: TenancyClient {
    let worker = worker
    return TenancyClient(
      deviceLinks: { Dictionary(self.cell.devices().compactMap { device in device.machine.map { ($0, device.id) } }, uniquingKeysWith: min) },
      deviceAccounts: { self.cell.deviceAccounts(machine: $0) },
      device: { self.cell.device(id: $0) },
      groups: { self.cell.groups().map(\.id) },
      group: { self.cell.resolve($0) },
      reach: { self.cell.reach(of: $0) },
      claimMachine: { id, name in _ = try await worker.call(SpaceCell.ID("space")) { try $0.claimMachine(id, name: name) } },
      annotateDevice: { id, machine in try await self.annotateDevice(id, name: nil, machine: machine) },
      detachMachine: { machine, account in _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.detachMachine(machine) } },
      freeMachine: { id in _ = try await worker.call(SpaceCell.ID("space")) { try $0.freeMachine(id) } },
      renameMachine: { id, name in _ = try await worker.call(SpaceCell.ID("space")) { try $0.renameMachine(id, name: name) } },
    )
  }

  /// What a machine's notes need of the group's file tree.
  public nonisolated var groupNotes: GroupNotes {
    let worker = worker
    let documents = documents
    return GroupNotes(
      checkpoint: { path, group in
        try await documents.checkpoint(under: SpacePath(validating: path), in: group)
      },
      move: { machine, from, to in
        _ = try await worker.call(FilesCell.ID(from.rawValue)) { try $0.moveMachineNotes(machine, to: to) }
      },
      delete: { machine, group in
        _ = try await worker.call(FilesCell.ID(group.rawValue)) { try $0.deleteMachineNotes(machine) }
      },
    )
  }

  /// The group's access rule for another family, asked by id.
  public nonisolated var groupClients: GroupClient {
    let worker = worker
    return GroupClient(
      roleOfSession: { id, group in worker.cell(GroupCell.ID(group.rawValue)).role(ofSession: id) },
      roleOfAccount: { account, acting, group in worker.cell(GroupCell.ID(group.rawValue)).role(ofAccount: account, acting: acting) },
      roleOfGroup: { source, group in worker.cell(GroupCell.ID(group.rawValue)).role(ofGroup: source) },
      isHumanAdmin: { account, group in worker.cell(GroupCell.ID(group.rawValue)).isHumanAdmin(account) },
      writes: { source, group in worker.cell(GroupCell.ID(group.rawValue)).writes(from: source) },
      exists: { group in worker.cell(GroupCell.ID(group.rawValue)).exists() },
    )
  }
}
