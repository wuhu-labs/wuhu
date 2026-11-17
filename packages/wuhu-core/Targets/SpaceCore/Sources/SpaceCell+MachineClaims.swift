import struct MachineContract.MachineID
import MachinesContract
import SpaceIDs
import StructuredQueries
import Wuwei

extension SpaceCell {
  /// Reserves a new machine's first name.
  mutating func claimMachine(_ id: MachineID, name: String) throws {
    try reserveMachineName(name, for: id)
  }

  /// Marks `name` the machine's current one; every spelling it ever had stays reserved.
  mutating func renameMachine(_ id: MachineID, name: String) throws {
    guard ctx.machine(id).group() != nil else { throw SpaceError.notFound(id.rawValue) }
    try reserveMachineName(name, for: id)
  }

  /// A name is free only when no machine holds it: every spelling a machine ever had stays reserved until that machine
  /// is deleted, which frees them all. A name a machine holds says whom to delete.
  private mutating func reserveMachineName(_ name: String, for id: MachineID) throws {
    do {
      try setCurrentAlias(name, kind: .machine, target: id.rawValue)
    } catch AliasError.taken {
      guard let held = db.rows(AliasRow.where { $0.name.eq(name) }).first, held.kind == .machine else { throw SpaceError.machineNameTaken(name) }
      throw SpaceError.machineNameTakenByMachine(name)
    }
  }
}
