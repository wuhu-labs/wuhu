import JSONValue
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension MachineCell {
  enum FileDriveOutcome: Equatable {
    case unchanged, changed, settled
  }

  mutating func finishFileStep(_ row: inout MachineFileOperation, presence: MachinePresence) throws {
    let presence = try prepareDrive(presence)
    if presence.state != "deleted", let lease = presence.lease, lease > now,
       let box, let runtime = presence.runtime,
       try driveFile(&row, box: box, runtime: runtime) == .settled { return }
    try saveFile(row)
  }

  mutating func driveFile(_ row: inout MachineFileOperation, box: SocketHandle<BoxSocket>, runtime: MachineRuntime, description: MachineDescription? = nil) throws -> FileDriveOutcome {
    if try resetFileWorker(&row) { return .settled }
    let limits = runtime
    let hold = min(limits.pollHoldMs, limits.leaseMs / 3)
    let limit = min(limits.pollBytes, 65536)
    var changed = false
    if !row.dispatched {
      guard let description else { return .unchanged }
      if let stop = row.stop {
        try failFile(&row, .operation(.init(.requestCancelled, message: stop)))
        return .settled
      }
      if let error = try fileAdmission(row.request.start, on: description, box: box) {
        try failFile(&row, .operation(error))
        return .settled
      }
      let kind = description.kinds.first { $0.name == row.request.start.kind }!
      row.offsets = Dictionary(uniqueKeysWithValues: kind.outputChannels.map { ($0.name, 0) })
      row.offered = row.offsets
      row.received = row.offsets
      row.inputOffsets = Dictionary(uniqueKeysWithValues: kind.inputChannels.map { ($0.name, 0) })
      row.inputChannels = kind.inputChannels
      row.dispatched = true; row.state = "starting"
      fileSocket(row)?.send(.started)
      requestFile(.start, .startFile(row.request.operation, row.request.start), row: &row, to: box)
      changed = true
    } else if row.flights[.start] == nil {
      if let stop = row.stop {
        changed = requestFile(.stop, .stop(row.request.operation, stop), row: &row, to: box) || changed
      } else if row.state == "reconciling", row.snapshot?.verdict == nil {
        changed = requestFile(.control, .poll(row.request.operation, channel: nil, after: 0, holdMs: hold, terminal: nil, limit: limit), row: &row, to: box) || changed
      } else if row.snapshot?.verdict == nil, let pending = buffers.pending(row.request.operation, accepted: row.inputOffsets, ended: row.inputEnded) {
        let channel = pending.0.channel
        let accepted = row.inputOffsets[channel]!
        let pointer = MachinePointer(worker: buffers.worker, operation: row.request.operation, channel: channel, from: max(accepted, pending.0.from), through: pending.0.through)
        guard buffers.payload(pointer) != nil else { try failFile(&row, .outcomeUnknown); return .settled }
        changed = requestFile(.fileInput(channel: channel), .fileInput(row.request.operation, pointer, end: pending.1), row: &row, to: box) || changed
      } else if row.snapshot?.verdict == nil {
        if row.flights.keys.contains(where: { if case .fileInput = $0 { true } else { false } }) {
          try failFile(&row, .outcomeUnknown); return .settled
        }
        changed = requestFile(.control, .poll(row.request.operation, channel: nil, after: 0, holdMs: hold, terminal: nil, limit: limit), row: &row, to: box) || changed
      }
      if row.stop == nil {
        for (channel, offset) in row.offsets {
          if row.endedChannels.contains(channel) { continue }
          let received = row.received[channel]!
          if let final = row.snapshot?.finalOffsets[channel], row.snapshot?.verdict != nil, received >= final.rawValue { continue }
          if let flight = row.flights[.output(channel)], flight.waiting || flight.due > now { continue }
          if buffers.retained(row.request.operation, channel: channel, from: offset) > (4 << 20) - limit { continue }
          changed = requestFile(.output(channel), .poll(row.request.operation, channel: channel, after: received, holdMs: hold, terminal: nil, limit: limit), row: &row, to: box) || changed
        }
      }
    }
    if row.failure == nil, let snapshot = row.snapshot, snapshot.verdict != nil,
       row.offsets.allSatisfy({ channel, offset in snapshot.finalOffsets[channel].map { offset >= $0.rawValue } == true })
    {
      if row.state != "draining" { row.state = "draining"; changed = true }
      if !row.delivered { try deliverFile(&row); changed = true }
      let channels = row.offsets.isEmpty ? [""] : Array(row.offsets.keys)
      for channel in channels where !row.terminalAcks.contains(channel) {
        changed = requestFile(.terminal(channel), .poll(row.request.operation, channel: channel.isEmpty ? nil : channel, after: row.offsets[channel] ?? 0, holdMs: 0, terminal: snapshot.terminalToken!, limit: limit), row: &row, to: box) || changed
      }
    }
    return changed ? .changed : .unchanged
  }

  @discardableResult mutating func requestFile(_ purpose: BoxPurpose, _ exchange: BoxExchange, row: inout MachineFileOperation, to box: SocketHandle<BoxSocket>) -> Bool {
    if let flight = row.flights[purpose], flight.waiting || flight.due > now { return false }
    let retry = row.flights[purpose]?.retry ?? 100
    let deadline: Int64 = switch exchange {
    case let .poll(_, _, _, hold, _, _): Int64(hold) + 5000
    default: 5000
    }
    row.flights[purpose] = ExecFlight(due: now + deadline, retry: retry)
    box.send(.init(tag: .operation(row.request.operation, purpose), exchange: exchange))
    return true
  }

  func fileAdmission(_ start: StartRequest, on description: MachineDescription, box: SocketHandle<BoxSocket>) throws -> OperationError? {
    if !description.acceptingStarts { return .init(.leaving, details: ["started": false]) }
    if let refusal = description.availability?[start.kind]?.refusal(kind: start.kind) { return refusal }
    guard let kind = description.kinds.first(where: { $0.name == start.kind }) else {
      return .init(
        start.kind == "search.v1" ? .kindUnavailable : .unknownKind,
        message: "Machine does not support \(start.kind): agent too old, upgrade",
        details: ["kind": .string(start.kind), "reason": "agentTooOld", "started": false],
      )
    }
    if let schema = kind.inputSchema.object, schema["additionalProperties"] == .bool(false),
       let properties = schema["properties"]?.object, let input = start.input.object
    {
      let unadvertised = input.keys.filter { properties[$0] == nil }.sorted()
      if !unadvertised.isEmpty {
        return .init(
          .kindUnavailable,
          message: "Machine does not support \(start.kind) with \(unadvertised.joined(separator: ", ")): agent too old, upgrade",
          details: ["kind": .string(start.kind), "reason": "agentTooOld", "started": false, "inputs": .array(unadvertised.map { .string($0) })],
        )
      }
    }
    if try JSONEncoder().encode(start).count > description.limits.inputBytes { return .init(.inputTooLarge) }
    let execs = db.rows(MachineOperation.live.where { $0.dispatched }.asSelect().count()).first!
    if execs * 3 + dispatchedFileStreams + fileStreamCount(inputs: kind.inputChannels.count, outputs: kind.outputChannels.count) > box.opening.streams - 2 { return .init(.capacityExceeded, message: "Machine tunnel capacity is full") }
    return nil
  }
}
