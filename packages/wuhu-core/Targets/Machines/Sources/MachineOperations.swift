import GroupContract
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import MachinesContract
import struct OperationProtocol.StartRequest
import struct SessionDomain.ToolCallID
import SpaceFS
import SpaceIDs
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import TenancyContract
import Wuwei

extension Machines {
  public func renameMachine(_ id: MachineID, name: String) async throws -> MachineRecord {
    let requested = try Self.requireMachineName(name)
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    try await tenancy.renameMachine(id, requested)
    return MachineRecord(id: record.id, name: requested, createdAt: record.createdAt, group: record.group, scope: record.scope)
  }

  /// Switches who may use a machine: its own group, or every group that can reach that one.
  public func setMachineScope(_ id: MachineID, scope: ReachScope) async throws -> MachineRecord {
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.scope(scope) }
    return MachineRecord(id: record.id, name: record.name, createdAt: record.createdAt, group: record.group, scope: scope)
  }

  public func moveMachine(_ id: MachineID, to group: GroupID) async throws -> MachineRecord {
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    let from = record.group
    try await notes.checkpoint("/_/machines/\(id.rawValue)", from)
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.move(from: from, to: group) }
    try await notes.move(id.rawValue, from, group)
    return MachineRecord(id: record.id, name: record.name, createdAt: record.createdAt, group: group, scope: record.scope)
  }

  /// The machine's last step: the caller authorized against `group`, its devices unlinked, then its row and notes go and
  /// its name is freed. A caller who is no human admin of that group may not.
  public func deleteMachine(_ id: MachineID, by caller: MachineCaller) async throws {
    guard let record = try await machine(id), try await machineV2Member(id) else { throw SpaceError.notFound(id.rawValue) }
    let group = record.group
    guard let account = caller.account, await groups.isHumanAdmin(account, group) else { throw SpaceError.groupForbidden(group.rawValue) }
    // The machine's row cannot go while a device names it: each owner lets its own go first, and a link that appears
    // in between fails the deletion call below, which the caller repeats.
    for account in await tenancy.deviceAccounts(id) {
      try await tenancy.detachMachine(id, account)
    }
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.delete(in: group) }
    try await notes.delete(id.rawValue, group)
    try await tenancy.freeMachine(id)
  }

  func machineV2Member(_ id: MachineID) async throws -> Bool {
    directoryCell.machineV2Member(id)
  }

  public func reserveExec(machine: MachineID, caller: String? = nil, group: GroupID? = nil, script: String? = nil, toolCall: ToolCallID? = nil) async throws -> ExecRecord {
    guard let machineRecord = try await self.machine(machine) else { throw SpaceError.notFound(machine.rawValue) }
    let session = caller.flatMap { ExecCallerSpelling.isMember($0) ? nil : SessionID(rawValue: $0) }
    let home: GroupID
    if let group { home = group }
    else if let session, let summary = await sessions(session) { home = summary.group }
    else { home = machineRecord.group }
    let operation = toolCall.map { UUID.deterministic("machine-exec", caller ?? "", $0.rawValue) } ?? UUID()
    let id = "ex_" + randomSuffix(ExecID.suffixLength)
    let request = MachineExec(id: id, operation: operation, createdAt: date(), group: home, caller: caller, session: session, toolCall: toolCall, script: script)
    _ = try await worker.call(MachineCell.ID(machine.rawValue)) { try $0.reserve(request) }
    return try await execRecord(ExecID(rawValue: id))!
  }

  /// `StartRequest.caller` for a start `session` caused: its id, title and group, read at start time.
  /// Display-only attribution, so a session that can't be read (gone, or no session at all) leaves it out rather than
  /// failing the start.
  public func startCaller(_ session: SessionID?) async -> StartRequest.Caller? {
    guard let session, let summary = await sessions(session) else { return nil }
    return .init(session: session.rawValue, title: summary.title, group: summary.group.rawValue)
  }

  private static func requireMachineName(_ raw: String) throws -> String {
    guard let normalized = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    return normalized
  }
}
