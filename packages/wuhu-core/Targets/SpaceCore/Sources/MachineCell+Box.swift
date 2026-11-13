#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import StructuredQueries
import Wuwei
import WuweiQueries

extension MachineCell {
  mutating func attachBox(_ socket: SocketHandle<BoxSocket>) throws {
    var p = try ensurePresence()
    let machine = ctx.id.key
    let pubkey = socket.opening.pubkey
    guard p.state != "deleted",
          let account = db.rows(MachineRow.where { $0.id.eq(machine) }).first?.accountID,
          !db.rows(BoxCredentialRow.where { $0.pubkey.eq(pubkey) && $0.accountID.eq(account) }).isEmpty
    else { socket.close(); return }
    if let lease = p.lease, lease <= now { p = try endLease(p) }
    for old in ctx.sockets(of: BoxSocket.self) where old.id != socket.id { old.close() }
    if p.state == "attached" { p.state = "handshaking" }
    p.describeAt = nil; p.describeDeadline = now + 5000
    socket.send(.init(tag: .describe, exchange: .describe))
    try save(p)
  }

  mutating func closeBox(_ socket: SocketHandle<BoxSocket>) throws {
    if let box, box.id != socket.id { return }
    var p = presence
    p.describeAt = nil; p.describeDeadline = nil
    try save(p)
    for var row in db.rows(MachineOperation.live) { row.flights = [:]; try save(row) }
    for var row in db.rows(MachineFileOperation.all) { row.flights = [:]; try saveFile(row) }
  }

  private mutating func reconcileBox(presence p: MachinePresence) throws {
    try resetFilesForBox(presence: p)
    for var row in db.rows(MachineOperation.live) {
      try stopOrphanStream(&row)
      row.flights = [:]
      if row.dispatched && row.state == "starting" { row.state = "reconciling" }
      row.stopSent = false
      try finishExecStep(&row, presence: p)
    }
  }

  private mutating func invalidResponse(_ row: inout MachineOperation) throws {
    if row.diagnostic == nil {
      Logger(label: "wuhu.machine").warning("machine operation failed", metadata: [
        "machine": "\(ctx.id.key)",
        "operation": "\(row.request.operation)",
        "kind": "exec.v1",
        "failure": "invalidResponse",
        "state": "\(row.state)",
        "input_offsets": .dictionary(["stdin": "\(row.stdin)"]),
        "input_ended": .array(row.stdinEnded ? ["stdin"] : []),
        "offsets": .dictionary(["stdout": "\(row.stdout)", "stderr": "\(row.stderr)"]),
        "final_offsets": .dictionary(row.snapshot?.finalOffsets.mapValues { .string(String($0.rawValue)) } ?? [:]),
      ])
    }
    try finish(&row, error: OperationError(.invalidResponse))
    try save(row)
  }

  mutating func answer(_ frame: BoxSocket.Incoming, from socket: SocketHandle<BoxSocket>) throws {
    guard box?.id == socket.id else { return }
    let before = presence
    if before.state != "attached", let deadline = before.describeDeadline, deadline <= now {
      try wake()
      return
    }
    var p = before
    if p.state == "attached" {
      switch frame.answer {
      case .description, .snapshot, .input, .box:
        p.lease = now + Int64(p.leaseMs)
      case .transport, .preparation: break
      }
    }
    if case .describe = frame.tag {
      switch frame.answer {
      case let .description(description):
        let exec = description.kinds.first { $0.name == "exec.v1" }
        let validChannels = exec.map { kind in
          ["stdout", "stderr"].allSatisfy { name in kind.outputChannels.contains { $0.name == name && $0.unit == .bytes && $0.windowBytes > 0 } }
        } ?? true
        let uniqueChannels = description.kinds.allSatisfy { kind in
          let channels = kind.inputChannels + kind.outputChannels
          return Set(channels.map(\.name)).count == channels.count
        }
        guard description.version == 2, description.limits.isValid, validChannels, uniqueChannels else {
          p.state = "lost"; p.lease = nil; p.describeAt = nil; p.describeDeadline = nil
          if p != before { try save(p) }
          for var row in db.rows(MachineFileOperation.all) {
            try failFile(&row, .operation(.init(.invalidResponse)), cleanup: false)
          }
          for var row in db.rows(MachineOperation.live.where { $0.opened }) {
            try invalidResponse(&row)
          }
          socket.close()
          return
        }
        if exec == nil {
          for var row in db.rows(MachineOperation.live.where { $0.dispatched }) {
            try finish(&row, error: OperationError(.unknownKind, message: "Machine does not support exec.v1"))
            try save(row)
          }
        }
        try save(MachineDescriptionRow(description: description))
        p.leaseMs = description.limits.leaseMs
        p.pollHoldMs = description.limits.pollHoldMs
        p.pollBytes = description.limits.pollBytes
        p.resultBytes = description.limits.resultBytes
        p.execStdoutWindow = exec?.outputChannels.first { $0.name == "stdout" }?.windowBytes
        p.execStderrWindow = exec?.outputChannels.first { $0.name == "stderr" }?.windowBytes
        p.filePieceBytes = description.limits.filePieceBytes
        p.state = "attached"; p.observed = now; p.describeDeadline = nil
        p.lease = now + Int64(description.limits.leaseMs)
        p.describeAt = now + Int64(description.limits.leaseMs / 3); p.describeRetry = 100
      case .box, .transport, .preparation:
        guard p.state == "attached" else { return }
        p.describeDeadline = nil
        p.describeAt = now + p.describeRetry; p.describeRetry = min(2000, p.describeRetry * 2)
      case .snapshot, .input: preconditionFailure("describe answered with operation data")
      }
      if p != before { try save(p) }
      if before.state != "attached", p.state == "attached" { try reconcileBox(presence: p) }
      return
    }
    precondition(p.state == "attached", "operation answered before the socket described")
    requestDescribe(&p, to: socket)
    if p != before { try save(p) }
    if case let .operation(op, purpose) = frame.tag, var row = fileOperation(op) {
      try answerFile(frame, row: &row, purpose: purpose, presence: p)
      return
    }
    guard case let .operation(op, purpose) = frame.tag,
          var row = db.rows(MachineOperation.live.where { $0.operation.eq(op.uuidString.lowercased()) }).first
    else {
      if case let .snapshot(answer) = frame.answer, let pointer = answer.output {
        let buffers = buffers
        ctx.emit { buffers.discard(pointer.operation) }
      }
      return
    }
    var retry = row.flights[purpose]?.retry ?? 100
    row.flights[purpose] = nil
    var stalled = false
    switch frame.answer {
    case let .box(error), let .transport(error):
      if purpose == .input, error.code == .operationEnded {
        row.stdinEnded = true
        let buffers = buffers
        ctx.emit { buffers.endInput(op) }
      } else if purpose == .start, error.code == .operationExists { row.state = "running" }
      else if error.code == .unknownOperation {
        if row.drained { row.state = "retired"; row.flights = [:] }
        else { try finish(&row, error: OperationError(.unknownOperation, message: "The start may not have reached the machine and was not retried; process outcome is unknown")) }
      } else if [.transport, .requestDeadline, .requestCancelled, .machineUnavailable, .supervisorUnavailable, .capacityExceeded].contains(error.code) {
        if purpose == .start { row.state = "reconciling" }
        else { row.flights[purpose] = ExecFlight(due: now + retry, retry: min(2000, retry * 2), waiting: false) }
      } else { try finish(&row, error: error) }
    case let .preparation(error):
      row.stop = nil
      try finish(&row, error: error)
    case let .snapshot(answer):
      let snapshot = answer.snapshot
      guard snapshot.operation == op, snapshot.verdict == nil || snapshot.terminalToken != nil else { try invalidResponse(&row); return }
      if let known = row.snapshot?.verdict, let verdict = snapshot.verdict, known != verdict { try invalidResponse(&row); return }
      let knownFinals = row.snapshot?.finalOffsets ?? [:]
      guard snapshot.finalOffsets.allSatisfy({ channel, offset in knownFinals[channel].map { $0 == offset } ?? true }) else { try invalidResponse(&row); return }
      var finals = knownFinals.merging(snapshot.finalOffsets) { known, _ in known }
      if snapshot.channelEnd {
        guard let channel = snapshot.channel, ["stdout", "stderr"].contains(channel),
              purpose == .output(channel) || purpose == .terminal(channel),
              let from = snapshot.from, let through = snapshot.through,
              through >= from, from.rawValue <= row.offset(channel), through.rawValue >= row.offset(channel),
              finals[channel].map({ $0 == through }) ?? true
        else { try invalidResponse(&row); return }
        finals[channel] = through
      }
      guard ["stdout", "stderr"].allSatisfy({ channel in
        guard let final = finals[channel]?.rawValue else { return true }
        let offset = row.offset(channel)
        return row.endedChannels.contains(channel) ? offset == final : offset <= final
      }) else { try invalidResponse(&row); return }
      var progressed = row.snapshot?.verdict == nil && snapshot.verdict != nil
      switch purpose {
      case .start:
        if row.state == "starting" { row.state = "running" }
      case .stop: row.stopSent = true
      case let .output(channel):
        guard snapshot.channel == channel, let from = snapshot.from, let through = snapshot.through else { try invalidResponse(&row); return }
        let offset = row.offset(channel)
        let advancing = from.rawValue == offset && through > from
        guard !advancing || !row.endedChannels.contains(channel),
              finals[channel].map({ through.rawValue <= $0.rawValue }) ?? true
        else { try invalidResponse(&row); return }
        if advancing {
          progressed = true
          guard let pointer = answer.output, pointer.operation == op, pointer.channel == channel, pointer.from == from.rawValue, pointer.through == through.rawValue else { try invalidResponse(&row); return }
          let count = Int(through.rawValue - from.rawValue)
          let admitted = min(count, max(0, (row.request.maxOutput ?? Int.max) - row.cursor))
          if channel == "stdout" { row.stdout = through.rawValue } else { row.stderr = through.rawValue }
          if admitted > 0 {
            let tail = admitted == count ? answer.tail : Data(buffers.read(pointer)!.prefix(admitted).suffix(51200))
            let output = admitted == count ? pointer : buffers.prefix(pointer, count: admitted)
            row.tail.append(tail); row.tail = row.tail.suffix(51200)
            row.cursor += admitted
            let streams = ctx.sockets(of: ExecStream.self).filter { $0.opening.nonce == row.stream }
            if !streams.isEmpty {
              buffers.delivered(output, cursor: row.cursor)
              for stream in streams { stream.send(.output(output, cursor: row.cursor)) }
            } else {
              let buffers = buffers
              ctx.emit { buffers.remove(output) }
            }
            if admitted != count {
              let buffers = buffers
              ctx.emit { buffers.remove(pointer) }
            }
          } else {
            let buffers = buffers
            ctx.emit { buffers.remove(pointer) }
          }
          if let max = row.request.maxOutput, row.cursor >= max {
            row.cut = row.cursor; row.stop = row.stop ?? "outputLimit"; row.state = "stopping"
          }
        }
        if snapshot.channelEnd, from.rawValue == offset, through.rawValue == offset {
          row.endedChannels.insert(channel)
        }
      case .control:
        if row.state == "starting" { row.state = "running"; progressed = true }
      case let .terminal(channel):
        row.terminalAcks.insert(channel)
      case .input: preconditionFailure("input answered with snapshot")
      case .fileInput: preconditionFailure("Exec received file input response")
      }
      guard ["stdout", "stderr"].allSatisfy({ channel in
        guard let final = finals[channel]?.rawValue else { return true }
        let offset = row.offset(channel)
        return row.endedChannels.contains(channel) ? offset == final : offset <= final
      }) else { try invalidResponse(&row); return }
      if case .terminal = purpose, snapshot.outputConsumed, row.terminalAcks.isSuperset(of: ["stdout", "stderr"]) {
        row.state = "retired"; row.flights = [:]
      }
      let latest = row.snapshot?.verdict == nil || snapshot.verdict != nil ? snapshot : row.snapshot!
      row.snapshot = OperationSnapshot(
        operation: latest.operation, verdict: latest.verdict, terminalToken: latest.terminalToken,
        finalOffsets: finals, outputConsumed: latest.outputConsumed, channel: latest.channel,
        from: latest.from, through: latest.through, payload: latest.payload, channelEnd: latest.channelEnd,
        bufferReservationBytes: latest.bufferReservationBytes,
      )
      if row.snapshot?.verdict != nil { row.flights[.control] = nil; row.flights[.input] = nil; row.flights[.stop] = nil }
      switch purpose {
      case .control: stalled = !progressed && row.snapshot?.verdict == nil
      case let .output(channel): stalled = !progressed && !row.endedChannels.contains(channel)
      case .terminal: stalled = !row.terminal
      case .start, .stop, .input: break
      case .fileInput: preconditionFailure("Exec received file input response")
      }
    case let .input(receipt):
      precondition(purpose == .input)
      let progressed = receipt.acceptedThrough.rawValue >= row.stdin && (receipt.acceptedThrough.rawValue > row.stdin || receipt.end && !row.stdinEnded)
      if receipt.acceptedThrough.rawValue >= row.stdin {
        row.stdin = receipt.acceptedThrough.rawValue
        row.stdinEnded = row.stdinEnded || receipt.end
        let buffers = buffers
        let accepted = row.stdin
        let ended = row.stdinEnded
        ctx.emit { buffers.accepted(op, through: accepted, ended: ended) }
        for stream in ctx.sockets(of: ExecStream.self) where stream.opening.nonce == row.stream { stream.send(.accepted(row.stdin)) }
      }
      if progressed { retry = 100 }
      stalled = row.snapshot?.verdict == nil && !row.stdinEnded && (receipt.blocked || !progressed)
    case .description: preconditionFailure("operation answered with description")
    }
    if stalled {
      let delay = min(retry, max(1, (p.lease! - now) / 3))
      row.flights[purpose] = ExecFlight(due: now + delay, retry: min(2000, retry * 2), waiting: false)
    }
    try finishExecStep(&row, presence: p)
  }
}

@Table("account_keys")
private struct BoxCredentialRow {
  @Column("pubkey", primaryKey: true) var pubkey: String
  @Column("account_id") var accountID: String
}
