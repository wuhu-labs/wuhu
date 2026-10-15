#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SessionDomain.ToolCallID
import struct SpaceContract.GroupID
import struct SpaceCore.ExecClaim
import struct SpaceCore.ExecRecord
import enum SpaceCore.ExecTerminalState
import struct WorkerProtocol.WorkerProtocolError

struct ExecTerminalSnapshot: Codable, Sendable {
  let kind: String
  let value: Int?
  init(_ state: ExecTerminalState) {
    switch state {
    case let .exited(code): kind = "exited"; value = code
    case let .signaled(signal): kind = "signaled"; value = signal
    case .cancelled: kind = "cancelled"; value = nil
    case .reaped: kind = "reaped"; value = nil
    case .machineLost: kind = "machineLost"; value = nil
    }
  }

  func state() throws -> ExecTerminalState {
    switch kind {
    case "exited": if let value { return .exited(code: value) }
    case "signaled": if let value { return .signaled(signal: value) }
    case "cancelled" where value == nil: return .cancelled
    case "reaped" where value == nil: return .reaped
    case "machineLost" where value == nil: return .machineLost
    default: break
    }
    throw WorkerProtocolError(.invalidMessage, message: "Invalid exec terminal snapshot")
  }
}

struct ExecSnapshot: Codable, Sendable {
  let id: ExecID
  let machine: MachineID
  let streamID: Int
  let command: String
  let caller: String?
  let toolCallID: ToolCallID?
  let startedAt: Date
  let terminal: ExecTerminalSnapshot?
  let killDelivered: Bool
  let group: GroupID
  init(_ record: ExecRecord) {
    id = record.id; machine = record.machine; streamID = record.streamID; command = record.command; caller = record.caller; toolCallID = record.toolCallID; startedAt = record.startedAt; terminal = record.terminal.map(ExecTerminalSnapshot.init); killDelivered = record.killDelivered; group = record.group
  }

  func value() throws -> ExecRecord {
    try .init(id: id, machine: machine, streamID: streamID, command: command, caller: caller, toolCallID: toolCallID, startedAt: startedAt, terminal: terminal?.state(), killDelivered: killDelivered, group: group)
  }
}

struct ExecClaimSnapshot: Codable, Sendable {
  let record: ExecSnapshot
  let rejoined: Bool
  init(_ claim: ExecClaim) { record = .init(claim.record); rejoined = claim.rejoined }
  func value() throws -> ExecClaim { try .init(record: record.value(), rejoined: rejoined) }
}
