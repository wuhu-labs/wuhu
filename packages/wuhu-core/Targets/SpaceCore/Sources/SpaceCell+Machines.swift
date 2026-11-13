import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SessionDomain.ToolCallID
import struct SpaceContract.GroupID
import StructuredQueries
import WuweiQueries

@Selection private struct MachineExecRead {
  var row: MachineOperation
  var machine: String
}

/// A machine's folder in its group's tree: the notes are stored by id and listed under the machine's current name.
struct MachineFolder {
  let id: String
  let name: String?
}

extension SpaceCell {
  func machine(account: AccountID) -> MachineRecord? {
    guard let row = db.rows(MachineRow.where { $0.accountID.eq(account.rawValue) }).first else { return nil }
    return Space.machineRecord(from: row, name: currentName(of: row.id))
  }

  func machine(named name: String) -> MachineRecord? {
    let lowered = name.lowercased().replacingOccurrences(of: "-", with: "_")
    guard let alias = db.rows(AliasRow.where { $0.name.eq(lowered) && $0.kind.eq(AliasKind.machine) }).first,
          let row = db.rows(MachineRow.where { $0.id.eq(alias.target) }).first else { return nil }
    return Space.machineRecord(from: row, name: currentName(of: row.id))
  }

  func machines() -> [MachineRecord] {
    let names = machineNames()
    return db.rows(MachineRow.order { $0.id }).map { Space.machineRecord(from: $0, name: names[$0.id]) }
  }

  func machines(usableFrom group: GroupID) -> [MachineRecord] {
    let snapshot = machineAccess
    return machines().filter { Self.canUse($0, from: group, snapshot: snapshot) }
  }

  func canUse(_ record: MachineRecord, from group: GroupID) -> Bool {
    Self.canUse(record, from: group, snapshot: machineAccess)
  }

  func machineV2Member(_ id: MachineID) -> Bool {
    !db.rows(MachineV2MemberRow.where { $0.machineID.eq(id.rawValue) }).isEmpty
  }

  /// An enrolled v2 identity: a machine row whose membership names the group the row carries, in one statement so a
  /// move between two reads cannot refuse a valid token.
  func isMachineV2Account(_ account: AccountID) -> Bool {
    db.rows(MachineRow.where { $0.accountID.eq(account.rawValue) }
      .join(MachineV2MemberRow.all) { machine, member in machine.id.eq(member.machineID) && member.grp.eq(machine.grp) }
      .select { machine, _ in #sql("1", as: Bool.self) }).first ?? false
  }

  func machineFolders(group: GroupID, limit: Int?, byteLimit: Int?) throws -> [MachineFolder] {
    let names = machineNames()
    let machines = db.rows(MachineRow.where { $0.grp.eq(group.rawValue) })
      .map { MachineFolder(id: $0.id, name: names[$0.id]) }
      .sorted { ($0.name ?? $0.id, $0.id) < ($1.name ?? $1.id, $1.id) }
      .prefix(limit ?? Int.max)
    var budget = ListingBudget(limit: byteLimit)
    for machine in machines { try budget.consume(machine.name ?? machine.id) }
    return Array(machines)
  }

  func machineFolder(_ reference: String) -> String? {
    let lowered = reference.lowercased().replacingOccurrences(of: "-", with: "_")
    return db.rows(MachineRow.where { $0.id.eq(lowered) }).first?.id ?? machine(named: lowered)?.id.rawValue
  }

  func machineV2Members(group: GroupID) -> [String] {
    db.rows(MachineV2MemberRow.where { $0.grp.eq(group.rawValue) }).map(\.machineID)
  }

  /// The machine a spelling names, current or retired; nil once its machine is deleted and the reservation freed.
  func machineAlias(_ spelling: String) -> String? {
    db.rows(AliasRow.where { $0.name.eq(spelling.lowercased()) && $0.kind.eq(AliasKind.machine) }).first?.target
  }

  /// A machine's current alias: the only place its name lives.
  func currentName(of machine: String) -> String? {
    db.rows(AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.target.eq(machine) && $0.current }).first?.name
  }

  private func machineNames() -> [String: String] {
    Dictionary(uniqueKeysWithValues: db.rows(AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.current }).map { ($0.target, $0.name) })
  }

  private var machineAccess: GroupAccess.Snapshot {
    GroupAccess.Snapshot(groups: db.rows(GroupRow.all), roles: db.rows(GroupRoleRow.all))
  }

  private static func canUse(_ record: MachineRecord, from group: GroupID, snapshot: GroupAccess.Snapshot) -> Bool {
    switch record.scope {
    case .owner: group == record.group
    case .reachable: (snapshot.role(from: group.rawValue, in: record.group.rawValue) ?? .read) >= .write
    }
  }

  func execRequest(_ id: ExecID) -> MachineExec? {
    db.rows(MachineOperation.unscoped.where { $0.id.eq(id.rawValue) }).first?.request
  }

  func execRecord(_ id: ExecID) -> ExecRecord? {
    db.rows(MachineOperation.unscoped.where { $0.id.eq(id.rawValue) }
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).first.map(Self.execRecord)
  }

  func execRecord(caller: String, toolCallID: ToolCallID) -> ExecRecord? {
    db.rows(MachineOperation.unscoped.where { $0.caller.eq(caller) && $0.toolCall.eq(toolCallID.rawValue) }
      .order { ($0.created, $0.id) }.limit(1)
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).first.map(Self.execRecord)
  }

  func liveExecs() -> [ExecRecord] {
    db.rows(MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") }.order { ($0.created, $0.id) }
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).map(Self.execRecord)
  }

  func liveToolExecs(caller: String) -> [ExecRecord] {
    db.rows(MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") && $0.caller.eq(caller) && $0.toolCall.isNot(nil) }.order { ($0.created, $0.id) }
      .select { MachineExecRead.Columns(row: $0, machine: #sql("owner", as: String.self)) }).map(Self.execRecord)
  }

  func liveScriptExecs(script: String, caller: String) -> [ExecID] {
    db.rows(MachineOperation.unscoped.where { !$0.delivered && $0.state.neq("retired") && $0.script.eq(script) && $0.caller.eq(caller) }
      .select(\.id)).map { ExecID(rawValue: $0) }
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
