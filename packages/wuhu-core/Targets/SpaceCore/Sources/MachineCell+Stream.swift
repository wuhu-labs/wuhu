import struct OperationProtocol.OperationError
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension MachineCell {
  mutating func stopOrphanStream(_ row: inout MachineOperation) throws {
    guard row.opened, row.recipient == nil, !row.background, let stream = row.stream,
          !ctx.sockets(of: ExecStream.self).contains(where: { $0.opening.nonce == stream }) else { return }
    row.stream = nil
    if !row.delivered && row.stop == nil { try requestStop(&row, reason: "callerGone") }
  }

  mutating func openStream(_ socket: SocketHandle<ExecStream>) throws {
    let request = socket.opening.exec
    let p = try ensurePresence()
    if p.state == "deleted" { socket.close(); return }
    guard var row = operation(request.id), row.request.caller == request.caller, row.request.group == request.group else { socket.close(); return }
    if row.opened { socket.close(); return }
    if row.terminal { socket.send(.exit(result(row))); socket.close(); return }
    let refusal = invalidInput(request) ?? (request.argv.isEmpty || request.window < 128 * 1024 || request.window > 4 << 20 ? OperationError(.invalidInput) : nil)
    if let refusal {
      try finish(&row, error: refusal)
      try finishExecStep(&row, presence: p)
      socket.send(.exit(result(row))); socket.close()
      return
    }
    row.request = request; row.opened = true
    if let refusal = admission(box) {
      try finish(&row, error: refusal)
      try finishExecStep(&row, presence: p)
      socket.send(.exit(result(row))); socket.close()
      return
    }
    row.stream = socket.opening.nonce
    row.stopAt = request.timeout.map { now + Int64(min($0, 1e9) * 1000) }
    try finishExecStep(&row, presence: p)
    socket.send(.accepted(row.stdin))
  }

  mutating func stream(_ frame: ExecStream.Incoming, from socket: SocketHandle<ExecStream>) throws {
    guard var row = operation(socket.opening.exec.id), row.stream == socket.opening.nonce, !row.terminal else { return }
    switch frame {
    case let .stdin(pointer):
      guard pointer.operation == row.request.operation, pointer.channel == "stdin", pointer.worker == buffers.worker,
            pointer.through >= pointer.from else { socket.close(); return }
      if pointer.through <= row.stdin {
        socket.send(.accepted(row.stdin))
        let buffers = buffers
        ctx.emit { buffers.remove(pointer) }
        return
      }
      guard !row.stdinEnded, buffers.pend(pointer, end: false, accepted: row.stdin, window: row.request.window, piece: 65536) else { socket.close(); return }
      if pointer.from < row.stdin { socket.send(.accepted(row.stdin)) }
    case let .eof(offset):
      guard offset >= row.stdin else { socket.close(); return }
      if row.stdinEnded {
        guard offset == row.stdin else { socket.close(); return }
        socket.send(.accepted(row.stdin)); return
      }
      let pointer = buffers.put(Data(), operation: row.request.operation, channel: "stdin", from: offset)!
      guard buffers.pend(pointer, end: true, accepted: row.stdin, window: row.request.window, piece: 65536) else { socket.close(); return }
    case .kill:
      if !row.delivered { try requestStop(&row, reason: "callerCancelled"); try finishExecStep(&row, presence: presence) }
      return
    case let .consumed(cursor):
      guard cursor >= row.consumed, cursor <= row.cursor else { socket.close(); return }
      row.consumed = cursor
      let buffers = buffers
      let operation = row.request.operation
      ctx.emit { buffers.consumed(operation, cursor: cursor) }
    }
    try finishExecStep(&row, presence: presence)
  }

  mutating func closeStream(_ socket: SocketHandle<ExecStream>) throws {
    guard var row = operation(socket.opening.exec.id), row.stream == socket.opening.nonce, !row.background, !row.terminal, !row.delivered else { return }
    try requestStop(&row, reason: "callerGone")
    try finishExecStep(&row, presence: presence)
    let buffers = buffers
    let operation = row.request.operation
    ctx.emit { buffers.discard(operation) }
  }
}
