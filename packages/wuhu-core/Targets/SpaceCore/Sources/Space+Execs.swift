#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import OperationProtocol
import SessionDomain
import struct SpaceContract.GroupID

extension Space {
  public func machineDescription(_ machine: MachineID) async throws -> MachineDescription? {
    worker.cell(MachineCell.ID(machine.rawValue)).attachedDescription()
  }

  public func reserveExec(machine: MachineID, caller: String? = nil, group: GroupID? = nil, script: String? = nil, toolCall: ToolCallID? = nil) async throws -> ExecRecord {
    guard let machineRecord = try await self.machine(machine) else { throw SpaceError.notFound(machine.rawValue) }
    let session = caller.flatMap { Observer.isMember($0) || Person.account(ofExecCaller: $0) != nil ? nil : SessionID(rawValue: $0) }
    let home: GroupID
    if let group { home = group }
    else if let session { home = try await sessions.record(session).group }
    else { home = machineRecord.group }
    let operation = toolCall.map { UUID.deterministic("machine-exec", caller ?? "", $0.rawValue) } ?? UUID()
    let id = "ex_" + randomSuffix(ExecID.suffixLength)
    let request = MachineExec(id: id, operation: operation, createdAt: dateGen.now, group: home, caller: caller, session: session, toolCall: toolCall, script: script)
    _ = try await worker.call(MachineCell.ID(machine.rawValue)) { try $0.reserve(request) }
    return try await execRecord(ExecID(rawValue: id))!
  }

  public func execRequest(_ id: ExecID) async throws -> MachineExec? {
    cell.execRequest(id)
  }

  public func execRecord(_ id: ExecID) async throws -> ExecRecord? {
    cell.execRecord(id)
  }

  public func execRecord(caller: String, toolCallID: ToolCallID) async throws -> ExecRecord? {
    cell.execRecord(caller: caller, toolCallID: toolCallID)
  }

  public func liveExecs() async throws -> [ExecRecord] {
    cell.liveExecs()
  }

  public func liveToolExecs(caller: String) async throws -> [ExecRecord] {
    cell.liveToolExecs(caller: caller)
  }

  public func liveScriptExecs(script: String, caller: String) async throws -> [ExecID] {
    cell.liveScriptExecs(script: script, caller: caller)
  }
}
