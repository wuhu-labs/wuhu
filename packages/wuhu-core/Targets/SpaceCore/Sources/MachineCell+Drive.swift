#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import StructuredQueries
import Wuwei
import WuweiQueries

extension MachineCell {
  mutating func drive() throws {
    guard let box else { return }
    var p = presence
    guard p.state != "deleted", let lease = p.lease, lease > now else { return }
    if requestDescribe(&p, to: box) { try save(p) }
    guard let runtime = p.runtime else { return }
    let files = db.rows(MachineFileOperation.all)
    let execs = db.rows(MachineOperation.live.where { $0.opened })
    let pending = files.contains { !$0.dispatched } || execs.contains { !$0.dispatched }
    let description = pending ? machineDescription : nil
    for var row in files {
      if try driveFile(&row, box: box, runtime: runtime, description: description) == .changed { try saveFile(row) }
    }
    for var row in execs {
      if try driveExec(&row, box: box, runtime: runtime, description: description) { try save(row) }
    }
  }

  @discardableResult func requestDescribe(_ p: inout MachinePresence, to box: SocketHandle<BoxSocket>) -> Bool {
    guard p.state != "deleted", let lease = p.lease, lease > now,
          let due = p.describeAt, due <= now, p.describeDeadline == nil else { return false }
    box.send(.init(tag: .describe, exchange: .describe))
    p.describeAt = nil; p.describeDeadline = now + 5000
    return true
  }

  mutating func prepareDrive(_ presence: MachinePresence) throws -> MachinePresence {
    var p = presence
    if let box, requestDescribe(&p, to: box) { try save(p) }
    return p
  }

  mutating func finishExecStep(_ row: inout MachineOperation, presence: MachinePresence) throws {
    let presence = try prepareDrive(presence)
    if presence.state != "deleted", let lease = presence.lease, lease > now, let box, let runtime = presence.runtime {
      try driveExec(&row, box: box, runtime: runtime)
    }
    try save(row)
  }

  @discardableResult mutating func driveExec(_ row: inout MachineOperation, box: SocketHandle<BoxSocket>, runtime: MachineRuntime, description: MachineDescription? = nil) throws -> Bool {
    guard row.opened, !row.terminal else { return false }
    var changed = false
    let limits = runtime
    let hold = min(limits.pollHoldMs, limits.leaseMs / 3)
    let pollBytes = min(limits.pollBytes, 65536)
    let buffers = buffers
    if !row.dispatched {
      guard let description else { return false }
      let exec = description.kinds.first { $0.name == "exec.v1" }
      if let stop = row.stop {
        try finish(&row, error: OperationError(.requestCancelled, message: stop))
      } else if let refusal = admission(box) { try finish(&row, error: refusal) }
      else if let refusal = description.availability?["exec.v1"]?.refusal(kind: "exec.v1") { try finish(&row, error: refusal) }
      else if exec == nil { try finish(&row, error: OperationError(.unknownKind, message: "Machine does not support exec.v1")) }
      else if !description.acceptingStarts { try finish(&row, error: OperationError(.leaving)) }
      else {
        row.dispatched = true; row.state = "starting"
        changed = request(.start, .start(row.request), row: &row, to: box) || changed
      }
      changed = true
    } else if row.flights[.start] == nil {
      if row.stop != nil && !row.stopSent && row.snapshot?.verdict == nil {
        changed = request(.stop, .stop(row.request.operation, row.stop!), row: &row, to: box) || changed
      } else if row.snapshot?.verdict == nil, row.stop == nil, !row.stdinEnded, let (pointer, end) = buffers.input(row.request.operation, accepted: row.stdin) {
        changed = request(.input, .input(row.request.operation, pointer, end: end), row: &row, to: box) || changed
      } else if row.snapshot?.verdict == nil {
        changed = request(.control, .poll(row.request.operation, channel: nil, after: 0, holdMs: hold, terminal: nil, limit: pollBytes), row: &row, to: box) || changed
      }
      for channel in ["stdout", "stderr"] {
        let offset = row.offset(channel)
        if row.endedChannels.contains(channel) { continue }
        if let snapshot = row.snapshot, snapshot.verdict != nil, let final = snapshot.finalOffsets[channel], offset >= final.rawValue { continue }
        let streaming = ctx.sockets(of: ExecStream.self).contains { $0.opening.nonce == row.stream }
        let channelRoom = min(row.request.window / 2, (channel == "stdout" ? runtime.execStdoutWindow : runtime.execStderrWindow)!)
        let poll = min(pollBytes, channelRoom)
        if streaming, buffers.retained(row.request.operation, channel: channel, consumed: row.consumed) + poll > channelRoom { continue }
        changed = request(.output(channel), .poll(row.request.operation, channel: channel, after: offset, holdMs: hold, terminal: nil, limit: poll), row: &row, to: box) || changed
      }
    }
    if row.drained {
      if row.state != "draining" { row.state = "draining"; changed = true }
      if !row.delivered { try deliver(&row); changed = true }
      for channel in ["stdout", "stderr"] {
        changed = request(.terminal(channel), .poll(row.request.operation, channel: channel, after: row.offset(channel), holdMs: 0, terminal: row.snapshot!.terminalToken!, limit: pollBytes), row: &row, to: box) || changed
      }
    }
    return changed
  }

  @discardableResult private mutating func request(_ purpose: BoxPurpose, _ exchange: BoxExchange, row: inout MachineOperation, to box: SocketHandle<BoxSocket>) -> Bool {
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
}
