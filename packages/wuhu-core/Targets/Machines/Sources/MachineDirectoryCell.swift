#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GroupContract
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import MachinesContract
import struct SessionDomain.ToolCallID
import SpaceIDs
import struct SpaceIDs.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

@Selection private struct MachineExecRead {
  var row: MachineOperation
  var machine: String
}

/// The machines as a whole, under the one key `machines`: the directory reads one machine owns no single cell, and every
/// read here is over the shared database.
@Cell
public struct MachineDirectoryCell: MachinesReading {
  public static let key = "machines"

  func row(pubkey: String) -> MachineRow? {
    db.rows(MachineRow.where { $0.pubkey.eq(pubkey) }).first
  }

  func machine(tokenHash: String) -> MachineID? {
    db.rows(MachineRow.where { $0.tokenHash.eq(tokenHash) }.select(\.id)).first.map(MachineID.init(rawValue:))
  }

  public func machine(named name: String) -> MachineRecord? {
    guard let id = ctx.space().machineID(named: name), let row = db.rows(MachineRow.where { $0.id.eq(id.rawValue) }).first else { return nil }
    return record(row)
  }

  public func machines() -> [MachineRecord] {
    let names = ctx.space().machineNames()
    return db.rows(MachineRow.order { $0.id }).map { record($0, name: names[MachineID(rawValue: $0.id)]) }
  }

  public func machines(usableFrom group: GroupID) -> [MachineRecord] {
    let writable = ctx.space().writableGroups(of: group)
    return machines().filter { Self.canUse($0, from: group, writable: writable) }
  }

  public func canUse(_ record: MachineRecord, from group: GroupID) -> Bool {
    switch record.scope {
    case .owner: group == record.group
    case .reachable: ctx.group(record.group).writes(from: group)
    }
  }

  public func machineV2Member(_ id: MachineID) -> Bool {
    !db.rows(MachineV2MemberRow.where { $0.machineID.eq(id.rawValue) }).isEmpty
  }

  public func machineFolders(group: GroupID) -> [MachineFolder] {
    let names = machineNames()
    return db.rows(MachineRow.where { $0.grp.eq(group.rawValue) })
      .map { MachineFolder(id: $0.id, name: names[MachineID(rawValue: $0.id)]) }
      .sorted { ($0.name ?? $0.id, $0.id) < ($1.name ?? $1.id, $1.id) }
  }

  public func machineFolder(_ reference: String) -> String? {
    let lowered = reference.lowercased().replacingOccurrences(of: "-", with: "_")
    if let row = db.rows(MachineRow.where { $0.id.eq(lowered) }).first { return row.id }
    return ctx.space().machineID(named: reference)?.rawValue
  }

  public func machineV2Members(group: GroupID) -> [String] {
    db.rows(MachineV2MemberRow.where { $0.grp.eq(group.rawValue) }).map(\.machineID)
  }

  public func execRequest(_ id: ExecID) -> MachineExec? {
    db.rows(MachineOperation.unscoped.where { $0.id.eq(id.rawValue) }).first?.request
  }

  public func execRecord(_ id: ExecID) -> ExecRecord? {
    db.rows(MachineOperation.unscoped.where { $0.id.eq(id.rawValue) }
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).first.map(Self.execRecord)
  }

  public func execRecord(caller: String, toolCallID: ToolCallID) -> ExecRecord? {
    db.rows(MachineOperation.unscoped.where { $0.caller.eq(caller) && $0.toolCall.eq(toolCallID.rawValue) }
      .order { ($0.created, $0.id) }.limit(1)
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).first.map(Self.execRecord)
  }

  public func liveExecs() -> [ExecRecord] {
    db.rows(MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") }.order { ($0.created, $0.id) }
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).map(Self.execRecord)
  }

  public func liveToolExecs(caller: String) -> [ExecRecord] {
    db.rows(MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") && $0.caller.eq(caller) && $0.toolCall.isNot(nil) }.order { ($0.created, $0.id) }
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).map(Self.execRecord)
  }

  public func liveScriptExecs(script: String, caller: String) -> [ExecID] {
    db.rows(MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") && $0.script.eq(script) && $0.caller.eq(caller) }
      .select(\.id)).map { ExecID(rawValue: $0) }
  }

  private func machineNames() -> [MachineID: String] { ctx.space().machineNames() }

  private func record(_ row: MachineRow, name: String? = nil) -> MachineRecord {
    MachineRecord(
      id: MachineID(rawValue: row.id),
      name: name ?? ctx.space().machineName(MachineID(rawValue: row.id)),
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      group: GroupID(rawValue: row.grp),
      scope: ReachScope(rawValue: row.scope) ?? .owner,
    )
  }

  private static func canUse(_ record: MachineRecord, from group: GroupID, writable: Set<GroupID>) -> Bool {
    switch record.scope {
    case .owner: group == record.group
    case .reachable: writable.contains(record.group)
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
