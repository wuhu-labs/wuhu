import struct MachineContract.MachineID
import StructuredQueries
import Wuwei

extension SpaceCell {
  /// Reserves the machine's name and mails its account's cell the birth, in one step: a crash after the claim cannot
  /// leave a name naming nothing, and the account's cell hands the row to the machine's.
  mutating func claimMachine(_ claim: MachineClaim) throws {
    try reserveMachineName(claim.name, for: claim.id)
    ctx.send(PersonCell.ID(claim.account.rawValue)).machineAccount(claim)
  }

  /// Marks `name` the machine's current one; every spelling it ever had stays reserved.
  mutating func renameMachine(_ id: MachineID, name: String) throws {
    guard ctx.cell(MachineCell.ID(id.rawValue)).record() != nil else { throw SpaceError.notFound(id.rawValue) }
    try reserveMachineName(name, for: id)
  }

  /// The name a joining box asks for, suffixed until free, as a join is better served than failed.
  mutating func claimMachineName(_ id: MachineID, preferred: String) throws -> String {
    guard ctx.cell(MachineCell.ID(id.rawValue)).record() != nil else { throw SpaceError.notFound(id.rawValue) }
    var candidate = preferred
    var ordinal = 1
    while true {
      do {
        try reserveMachineName(candidate, for: id)
        return candidate
      } catch SpaceError.machineNameTaken, SpaceError.machineNameTakenByMachine {
        ordinal += 1
        let suffix = "_\(ordinal)"
        candidate = String(preferred.prefix(63 - suffix.count)) + suffix
      }
    }
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
