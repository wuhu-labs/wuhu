#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import MachineContract
import OperationProtocol
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

@Selection private struct MachineExecRead {
  var row: MachineOperation
  var machine: String
}

extension Space {
  public func machineDescription(_ machine: MachineID) async throws -> MachineDescription? {
    try await writer.read { db in
      guard try MachinePresence.unscoped.where({ #sql("owner", as: String.self).eq(machine.rawValue) && $0.state.eq("attached") }).select(\.state).fetchOne(db) != nil else { return nil }
      return try MachineDescriptionRow.unscoped.where { _ in #sql("owner", as: String.self).eq(machine.rawValue) }.fetchOne(db)?.description
    }
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
    _ = worker
    return try await writer.read { db in
      try MachineOperation.unscoped.where { $0.id.eq(id.rawValue) }.fetchOne(db)?.request
    }
  }

  public func execRecord(_ id: ExecID) async throws -> ExecRecord? {
    _ = worker
    return try await writer.read { db in
      try MachineOperation.unscoped.where { $0.id.eq(id.rawValue) }
        .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }.fetchOne(db).map(Self.execRecord)
    }
  }

  public func execRecord(caller: String, toolCallID: ToolCallID) async throws -> ExecRecord? {
    _ = worker
    return try await writer.read { db in
      try MachineOperation.unscoped.where { $0.caller.eq(caller) && $0.toolCall.eq(toolCallID.rawValue) }
        .order { ($0.created, $0.id) }
        .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }.fetchOne(db).map(Self.execRecord)
    }
  }

  public func liveExecs() async throws -> [ExecRecord] {
    _ = worker
    return try await writer.read { db in
      try MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") }.order { ($0.created, $0.id) }
        .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }.fetchAll(db).map(Self.execRecord)
    }
  }

  public func liveToolExecs(caller: String) async throws -> [ExecRecord] {
    _ = worker
    return try await writer.read { db in
      try MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") && $0.caller.eq(caller) && $0.toolCall.isNot(nil) }.order { ($0.created, $0.id) }
        .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }.fetchAll(db).map(Self.execRecord)
    }
  }

  public func liveScriptExecs(script: String, caller: String) async throws -> [ExecID] {
    _ = worker
    return try await writer.read { db in
      try MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") && $0.script.eq(script) && $0.caller.eq(caller) }
        .select(\.id).fetchAll(db).map { ExecID(rawValue: $0) }
    }
  }

  private static func execRecord(_ read: MachineExecRead) -> ExecRecord {
    let row = read.row
    let request = row.request
    let terminal: ExecTerminalState?
    if row.delivered || row.terminal {
      let termination = row.snapshot?.verdict?.result?.object?["termination"]?.object
      if termination?["tag"]?.stringValue == "exit", let code = termination?["code"]?.intValue { terminal = .exited(code: code) }
      else if termination?["tag"]?.stringValue == "signal", let signal = termination?["signal"]?.intValue { terminal = .signaled(signal: signal) }
      else if row.stop != nil { terminal = .cancelled }
      else if !row.opened { terminal = .reaped }
      else { terminal = .machineLost }
    } else { terminal = nil }
    return ExecRecord(id: ExecID(rawValue: request.id), machine: MachineID(rawValue: read.machine), streamID: 1, command: request.argv.joined(separator: " "), caller: request.caller, toolCallID: request.toolCall, startedAt: request.createdAt, terminal: terminal, killDelivered: row.stopSent, group: request.group, background: row.background)
  }
}
