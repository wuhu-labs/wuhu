import GroupContract
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct OperationProtocol.OperationError
import struct SessionDomain.ToolCallID
import func SpaceContract.normalizedLabel
import SpaceIDs
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct MachineRecord: Equatable, Sendable {
  public let id: MachineID
  public let name: String?
  public let createdAt: Date
  /// The group the machine belongs to: groups that can use it may exec on it.
  public let group: GroupID
  /// Who may use it: its own group, or every group that can reach that one.
  public let scope: ReachScope

  public init(id: MachineID, name: String?, createdAt: Date, group: GroupID, scope: ReachScope = .owner) {
    self.id = id; self.name = name; self.createdAt = createdAt; self.group = group; self.scope = scope
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
  public var session: SessionID? {
    caller.flatMap { ExecCallerSpelling.session($0) }
  }
}

public enum MachineV2Presence: String, Sendable { case attached, detached, lost }

public struct MachineV2PresenceEvidence: Sendable {
  public let state: MachineV2Presence
  public let observedAt: Date
  public let reason: String?

  public init(state: MachineV2Presence, observedAt: Date, reason: String?) {
    self.state = state; self.observedAt = observedAt; self.reason = reason
  }
}

public enum MachineFileFailure: Error, Codable, Sendable {
  case operation(OperationError)
  case rangeLost(offset: UInt64)
  case outcomeUnknown
}
