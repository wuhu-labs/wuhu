#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID
import struct SpaceContract.GroupID
import func SpaceContract.normalizedLabel
import SpaceFS
import StructuredQueries

public struct MachineRecord: Equatable, Sendable {
  public let id: MachineID
  public let account: AccountID
  public let name: String?
  public let createdAt: Date
  /// The group the machine belongs to: groups that can use it may exec on it.
  public let group: GroupID
  /// Who may use it: its own group, or every group that can reach that one.
  public let scope: ReachScope

  public init(id: MachineID, account: AccountID, name: String?, createdAt: Date, group: GroupID, scope: ReachScope = .owner) {
    self.id = id; self.account = account; self.name = name; self.createdAt = createdAt; self.group = group; self.scope = scope
  }
}

public enum MachineName {
  public static func normalized(_ raw: String) -> String? {
    let mapped = raw.replacingOccurrences(of: "-", with: "_")
    guard !MachineID.isValid(mapped.lowercased()) else { return nil }
    return normalizedLabel(mapped, allowing: ["_", "."], length: 1 ... 63)
  }
}

public enum ExecTerminalState: Equatable, Sendable, Codable {
  case exited(code: Int)
  case signaled(signal: Int)
  case cancelled
  case reaped
  case machineLost

  var stored: String {
    switch self {
    case let .exited(code): "exited:\(code)"
    case let .signaled(signal): "signaled:\(signal)"
    case .cancelled: "cancelled"
    case .reaped: "reaped"
    case .machineLost: "machine-lost"
    }
  }

  init?(stored: String) {
    switch stored {
    case "cancelled": self = .cancelled
    case "reaped": self = .reaped
    case "machine-lost": self = .machineLost
    default:
      let parts = stored.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, let value = Int(parts[1]) else { return nil }
      switch parts[0] {
      case "exited": self = .exited(code: value)
      case "signaled": self = .signaled(signal: value)
      default: return nil
      }
    }
  }
}

public struct ExecRecord: Equatable, Sendable, Codable {
  public let id: ExecID
  public let machine: MachineID
  public let streamID: Int
  public let command: String
  public let caller: String?
  public let toolCallID: ToolCallID?
  public let toolSpec: String?
  /// Its tool call answered `running`: the relay keeps it without a caller and tells the session how it ended.
  public let background: Bool
  public let startedAt: Date
  public let terminal: ExecTerminalState?
  public let killDelivered: Bool
  /// The group the exec is homed in: groups that read it may see and join it.
  public let group: GroupID

  public init(id: ExecID, machine: MachineID, streamID: Int, command: String, caller: String?, toolCallID: ToolCallID?, startedAt: Date, terminal: ExecTerminalState?, killDelivered: Bool, group: GroupID, toolSpec: String? = nil, background: Bool = false) {
    self.id = id; self.machine = machine; self.streamID = streamID; self.command = command; self.caller = caller; self.toolCallID = toolCallID; self.startedAt = startedAt; self.terminal = terminal; self.killDelivered = killDelivered; self.group = group; self.toolSpec = toolSpec; self.background = background
  }

  /// The session that minted it: nil for an observer's, whose caller is its member.
  public var session: SessionID? { caller.flatMap { Observer.isMember($0) ? nil : SessionID(rawValue: $0) } }
}

extension Space {
  public func renameMachine(_ id: MachineID, name: String) async throws -> MachineRecord {
    let requested = try Self.requireMachineName(name)
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    _ = try await worker.call(SpaceCell.ID("space")) { try $0.renameMachine(id, name: requested) }
    return MachineRecord(id: record.id, account: record.account, name: requested, createdAt: record.createdAt, group: record.group, scope: record.scope)
  }

  // The default a joining box asks for: its hostname, suffixed until free, so a
  // second laptop called "mini" joins as "mini_2" instead of failing the join.
  public func claimMachineName(_ id: MachineID, preferred: String) async throws -> MachineRecord {
    let base = try Self.requireMachineName(preferred)
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    let name = try await worker.call(SpaceCell.ID("space")) { try $0.claimMachineName(id, preferred: base) }
    return MachineRecord(id: record.id, account: record.account, name: name, createdAt: record.createdAt, group: record.group, scope: record.scope)
  }

  public func machine(_ id: MachineID) async throws -> MachineRecord? {
    worker.cell(MachineCell.ID(id.rawValue)).record()
  }

  /// The group whose tree holds the machine's notes.
  public func machineGroup(_ id: MachineID) async throws -> GroupID {
    worker.cell(MachineCell.ID(id.rawValue)).record()?.group ?? .shared
  }

  public func machine(account: AccountID) async throws -> MachineRecord? {
    cell.machine(account: account)
  }

  public func machine(named name: String) async throws -> MachineRecord? {
    cell.machine(named: name)
  }

  public func resolveMachine(_ reference: String) async throws -> MachineRecord? {
    if let record = try await machine(MachineID(rawValue: reference)) { return record }
    return try await machine(named: reference)
  }

  // The dial-in oracle: resolves only through the LIVE key row, so kicking the
  // key row is what revokes the machine.
  public func machine(pubkey: String) async throws -> MachineID? {
    guard let key = try await credential(pubkey: pubkey), key.capabilities.contains(.execMachine) else { return nil }
    return try await machine(account: key.account)?.id
  }

  public func machines() async throws -> [MachineRecord] {
    cell.machines()
  }

  /// The machines `group` may use, by the same switch that admits a single
  /// one: the list shows only what it can exec on.
  public func machines(usableFrom group: GroupID) async throws -> [MachineRecord] {
    cell.machines(usableFrom: group)
  }

  /// A machine `group` may not use resolves as no machine at all.
  public func resolveMachine(_ reference: String, usableFrom group: GroupID) async throws -> MachineRecord? {
    guard let record = try await resolveMachine(reference) else { return nil }
    guard try await canUse(record, from: group) else { return nil }
    return record
  }

  /// Whether `group` may use `record`: `owner` is its own group alone;
  /// `reachable` is every group with write in its owner group.
  public func canUse(_ record: MachineRecord, from group: GroupID) async throws -> Bool {
    cell.canUse(record, from: group)
  }

  /// Switches who may use a machine: its own group, or every group that can
  /// reach that one.
  public func setMachineScope(_ id: MachineID, scope: ReachScope) async throws -> MachineRecord {
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.scope(scope) }
    return MachineRecord(id: record.id, account: record.account, name: record.name, createdAt: record.createdAt, group: record.group, scope: scope)
  }

  public func moveMachine(_ id: MachineID, to group: GroupID) async throws -> MachineRecord {
    let notes = try SpacePath(validating: "/_/machines/\(id.rawValue)")
    guard let record = try await machine(id) else { throw SpaceError.notFound(id.rawValue) }
    let from = record.group
    try await documents.checkpoint(under: notes, in: from)
    try await worker.call(MachineCell.ID(id.rawValue)) { try $0.move(from: from, to: group) }
    return MachineRecord(id: record.id, account: record.account, name: record.name, createdAt: record.createdAt, group: group, scope: record.scope)
  }

  func randomSuffix(_ count: Int) -> String {
    randomAlphanumericSuffix(count, rng: rng)
  }

  private static func requireMachineName(_ raw: String) throws -> String {
    guard let normalized = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    return normalized
  }

  static func machineRecord(from row: MachineRow, name: String?) -> MachineRecord {
    MachineRecord(
      id: MachineID(rawValue: row.id),
      account: AccountID(rawValue: row.accountID),
      name: name,
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      group: GroupID(rawValue: row.grp),
      scope: ReachScope(rawValue: row.scope) ?? .owner,
    )
  }
}
