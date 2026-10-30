#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct MachineContract.MachineID
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

extension Space {
  public func deleteMachine(_ id: MachineID, by principal: Principal) async throws {
    let notes = try SpacePath(validating: "/_/machines/\(id.rawValue)")
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
      guard let row = try MachineRow.where({ $0.id.eq(id.rawValue) }).fetchOne(db),
            try MachineV2MemberRow.where({ $0.machineID.eq(id.rawValue) }).fetchOne(db) != nil
      else {
        throw SpaceError.notFound(id.rawValue)
      }
      let group = GroupID(rawValue: row.grp)
      switch principal.actor {
      case .anonymous: break
      case let .person(_, account):
        guard let human = try GroupAccess.accountRow(account, in: db),
              try GroupAccess.Snapshot(db).isHumanAdmin(human, of: row.grp) else { throw SpaceError.groupForbidden(row.grp) }
      case .session, .observer, .page: throw SpaceError.groupForbidden(row.grp)
      }
      let rev = try Substrate.mintRevision(mtime: stamp, group: group, in: db)
      for node in try Substrate.descendantHeads(of: notes, group: group, in: db) {
        try LiveFS.remove(node, group: group, rev: rev, op: .delete, in: db)
        pending.append(MutationEvent(group: group, path: node.path, rev: Int(rev), kind: .delete, entry: nil))
      }
      let operations = MachineV2OperationRow.where { $0.machineID.eq(id.rawValue) }.select(\.id)
      try MachineV2RetentionRow.where { $0.id.in(operations) }.delete().execute(db)
      try MachineV2OperationRow.where { $0.machineID.eq(id.rawValue) }.delete().execute(db)
      try MachineV2PresenceRow.where { $0.machineID.eq(id.rawValue) }.delete().execute(db)
      try MachineV2MemberRow.where { $0.machineID.eq(id.rawValue) }.delete().execute(db)
      try DeviceRow.where { $0.machineID.eq(id.rawValue) }.update { $0.machineID = #bind(nil) }.execute(db)
      try MachineExecTerminalRow.where { $0.machineID.eq(id.rawValue) && $0.terminalState.is(nil) }
        .update { $0.terminalState = #bind(ExecTerminalState.machineLost.stored) }.execute(db)
      _ = try Self.purgeCredentials(account: AccountID(rawValue: row.accountID), in: db)
      try GroupRoleRow.where { $0.accountID.eq(row.accountID) }.delete().execute(db)
      try PersonaRow.where { $0.accountID.eq(row.accountID) }.delete().execute(db)
      let devices = DeviceRow.where { $0.accountID.eq(row.accountID) }.select(\.id)
      try DeviceCommandRow.where { $0.deviceID.in(devices) }.delete().execute(db)
      try MessageDeviceRow.where { $0.deviceID.in(devices) }.delete().execute(db)
      try DeviceRow.where { $0.accountID.eq(row.accountID) }.delete().execute(db)
      try db.execute(sql: "UPDATE account_keys SET created_by = NULL WHERE created_by = ?", arguments: [row.accountID])
      try db.execute(sql: "UPDATE join_tokens SET created_by = NULL WHERE created_by = ?", arguments: [row.accountID])
      try AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.target.eq(id.rawValue) }.delete().execute(db)
      try MachineRow.where { $0.id.eq(id.rawValue) }.delete().execute(db)
      try GroupAccountRow.where { $0.id.eq(row.accountID) }.delete().execute(db)
    }
  }
}

@Table("machine_execs")
private struct MachineExecTerminalRow {
  @Column(primaryKey: true) var id: String
  @Column("machine_id") var machineID: String
  @Column("terminal_state") var terminalState: String?
}
