#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import StructuredQueries
import Wuwei
import WuweiQueries

extension PersonCell {
  /// A device that named the machine no longer does; `machine` is the caller's fact, never this cell's.
  mutating func detachMachine(_ machine: MachineID) throws {
    try db.execute(DeviceRow.where { $0.accountID.eq(id.key) && $0.machineID.eq(machine.rawValue) }.update { $0.machineID = #bind(nil) })
  }

  /// The machine's own revocation: the presenting key must be this account's and live, and the purge is the same step,
  /// so a rotation lands wholly before (false) or wholly after it.
  mutating func revoke(machine: MachineID, presenting pubkey: String, at now: Date) throws -> Bool {
    guard let key = db.rows(PersonKeyRow.where { $0.accountID.eq(id.key) && $0.pubkey.eq(pubkey) }).first?.record,
          Space.isLive(key.expiresAt, at: now), key.capabilities.contains(.execMachine)
    else { return false }
    _ = try purgeCredentials()
    ctx.send(MachineCell.ID(machine.rawValue)).closeBoxes()
    return true
  }
}
