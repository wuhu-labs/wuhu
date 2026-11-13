import JSONValue
import Logging
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
  mutating func openFile(_ socket: SocketHandle<FileBulk>) throws {
    let opening = socket.opening
    let request = opening.request
    let p = try ensurePresence()
    guard p.state != "deleted", db.rows(MachineFileOperation.where { $0.id.eq(request.operation.uuidString.lowercased()) }.asSelect().count()).first! == 0 else { socket.close(); return }
    var row = MachineFileOperation(id: request.operation.uuidString.lowercased(), request: request, stream: socket.id, created: now)
    row.state = "pendingStart"
    row.worker = buffers.worker
    if p.state == "lost" || box == nil && (p.lease == nil || p.lease! <= now) {
      try failFile(&row, lostFile(row))
    } else {
      try finishFileStep(&row, presence: p)
    }
  }

  mutating func receiveFile(_ frame: FileBulk.Incoming, from socket: SocketHandle<FileBulk>) throws {
    guard var row = fileOperation(socket.opening.request.operation), row.stream == socket.id else { return }
    if try resetFileWorker(&row) { return }
    switch frame {
    case let .want(channel, offset):
      guard let before = row.offsets[channel], let offered = row.offered[channel], offset >= before, offset <= offered else { socket.close(); return }
      row.offsets[channel] = offset
      let buffers = buffers
      let operation = row.request.operation
      ctx.emit { buffers.release(operation, channel: channel, before: offset) }
      let received = row.received[channel]!
      if offset < received {
        guard var pointer = buffers.get(operation, channel: channel, from: offset) else {
          try failFile(&row, .rangeLost(offset: offset)); return
        }
        pointer.through = min(pointer.through, offset < offered ? offered : received, received)
        row.offered[channel] = max(offered, pointer.through)
        socket.send(.output(pointer))
      } else if try !offerFile(&row) { return }
    case let .input(pointer, end):
      guard row.inputReady, row.stop == nil, row.snapshot?.verdict == nil,
            pointer.operation == row.request.operation, pointer.worker == buffers.worker,
            pointer.through >= pointer.from,
            let accepted = row.inputOffsets[pointer.channel],
            let descriptor = row.inputChannels.first(where: { $0.name == pointer.channel })
      else { try failFile(&row, .operation(.init(.invalidInput))); return }
      if pointer.through <= accepted, !end || row.inputEnded.contains(pointer.channel) {
        socket.send(.accepted(channel: pointer.channel, offset: accepted, end: row.inputEnded.contains(pointer.channel)))
        return
      }
      guard let payload = buffers.payload(pointer) else { try failFile(&row, .outcomeUnknown); return }
      let piece = presence.piece
      let unitMatches = descriptor.unit == .bytes ? payload.data != nil : payload.records != nil
      guard unitMatches, UInt64(payload.count) == pointer.through - pointer.from, payload.count > 0 || end,
            payload.byteCount <= min(piece, descriptor.windowBytes),
            payload.records?.allSatisfy({ $0.jsonString().utf8.count <= descriptor.maxRecordBytes }) != false,
            !row.inputEnded.contains(pointer.channel), pointer.from == accepted
      else { try failFile(&row, .operation(.init(.invalidInput))); return }
      if let pending = buffers.pending(row.request.operation, accepted: row.inputOffsets, ended: row.inputEnded), pending.0 != pointer || pending.1 != end {
        try failFile(&row, .operation(.init(.invalidInput))); return
      }
      guard buffers.pend(pointer, end: end, accepted: accepted, window: descriptor.windowBytes, piece: piece) else {
        try failFile(&row, .operation(.init(.invalidInput))); return
      }
    case .cancel:
      row.stop = "callerCancelled"
      try failFile(&row, .operation(.init(.requestCancelled, message: "callerCancelled")))
      return
    }
    try finishFileStep(&row, presence: presence)
  }

  mutating func offerFile(_ row: inout MachineFileOperation) throws -> Bool {
    for (channel, offset) in row.offsets {
      guard offset < row.received[channel, default: 0] else { continue }
      if row.offered[channel, default: 0] > offset { continue }
      guard var pointer = buffers.get(row.request.operation, channel: channel, from: offset) else {
        try failFile(&row, .rangeLost(offset: offset))
        return false
      }
      pointer.through = min(pointer.through, row.received[channel]!)
      row.offered[channel] = pointer.through
      fileSocket(row)?.send(.output(pointer))
    }
    return true
  }

  mutating func closeFile(_ socket: SocketHandle<FileBulk>) throws {
    guard var row = fileOperation(socket.opening.request.operation), row.stream == socket.id, !row.delivered else { return }
    row.stop = "callerGone"; row.stream = nil; row.flights[.control] = nil
    try finishFileStep(&row, presence: presence)
    let buffers = buffers
    let operation = row.request.operation
    ctx.emit { buffers.discard(operation) }
  }

  func fileOperation(_ operation: UUID) -> MachineFileOperation? {
    db.rows(MachineFileOperation.where { $0.id.eq(operation.uuidString.lowercased()) }).first
  }

  mutating func saveFile(_ row: MachineFileOperation) throws {
    try db.execute(MachineFileOperation.where { $0.id.eq(row.id) }.delete())
    try db.execute(MachineFileOperation.insert { row })
  }

  func fileSocket(_ row: MachineFileOperation) -> SocketHandle<FileBulk>? {
    ctx.sockets(of: FileBulk.self).first { $0.id == row.stream && $0.opening.request.operation == row.request.operation && row.worker == buffers.worker }
  }

  mutating func deleteFile(_ row: MachineFileOperation) throws {
    try db.execute(MachineFileOperation.where { $0.id.eq(row.id) }.delete())
    let buffers = buffers
    let operation = row.request.operation
    ctx.emit { buffers.discard(operation) }
  }

  func lostFile(_ row: MachineFileOperation) -> MachineFileFailure {
    if !row.dispatched { return .operation(.init(.machineUnavailable, details: ["started": false])) }
    return switch row.request.start.kind {
    case "read.v1", "list.v1", "stat.v1", "search.v1": .rangeLost(offset: row.offsets.values.min() ?? 0)
    default: .outcomeUnknown
    }
  }

  mutating func failFile(_ row: inout MachineFileOperation, _ failure: MachineFileFailure, cleanup: Bool = true) throws {
    let diagnostic: String? = switch failure {
    case let .operation(error) where error.code == .invalidInput || error.code == .invalidResponse: error.code.rawValue
    case .outcomeUnknown: "outcomeUnknown"
    default: nil
    }
    if row.failure == nil, let diagnostic {
      Logger(label: "wuhu.machine").warning("machine operation failed", metadata: [
        "machine": "\(ctx.id.key)",
        "operation": "\(row.request.operation)",
        "kind": "\(row.request.start.kind)",
        "failure": "\(diagnostic)",
        "state": "\(row.state)",
        "input_offsets": .dictionary(row.inputOffsets.mapValues { .string(String($0)) }),
        "input_ended": .array(row.inputEnded.sorted().map { .string($0) }),
        "offsets": .dictionary(row.offsets.mapValues { .string(String($0)) }),
        "offered": .dictionary(row.offered.mapValues { .string(String($0)) }),
        "received": .dictionary(row.received.mapValues { .string(String($0)) }),
        "final_offsets": .dictionary(row.snapshot?.finalOffsets.mapValues { .string(String($0.rawValue)) } ?? [:]),
      ])
    }
    row.failure = failure
    row.flights = [:]
    if row.stop == nil {
      row.stop = switch failure {
      case let .operation(error): error.code.rawValue
      case .rangeLost: "rangeLost"
      case .outcomeUnknown: "outcomeUnknown"
      }
    }
    try deliverFile(&row)
    if cleanup, row.dispatched, let box {
      row.state = "stopping"
      if presence.state == "attached" { requestFile(.stop, .stop(row.request.operation, row.stop!), row: &row, to: box) }
      try saveFile(row)
    } else { try deleteFile(row) }
  }

  mutating func deliverFile(_ row: inout MachineFileOperation) throws {
    if row.delivered { return }
    let result: Result<JSONValue, MachineFileFailure>
    if let failure = row.failure { result = .failure(failure) }
    else {
      let verdict = row.snapshot!.verdict!
      switch verdict.tag {
      case .completed: result = .success(verdict.result!)
      case .failed: result = .failure(.operation(verdict.error!))
      case .stopped: result = .failure(.operation(.init(.operationEnded, message: verdict.reason!)))
      }
    }
    if let socket = fileSocket(row) { socket.send(.finished(result)); socket.close() }
    row.delivered = true
    let buffers = buffers
    let operation = row.request.operation
    ctx.emit { buffers.discard(operation) }
  }

  mutating func readyFile(_ row: inout MachineFileOperation, piece: Int) {
    if row.inputReady { return }
    row.inputReady = true
    fileSocket(row)?.send(.ready(inputs: row.inputChannels, piece: piece))
  }

  mutating func resetFileWorker(_ row: inout MachineFileOperation) throws -> Bool {
    if row.worker == buffers.worker { return false }
    let failure = lostFile(row)
    row.worker = buffers.worker
    row.stream = nil
    try failFile(&row, failure)
    return true
  }

  mutating func resetFilesForBox(presence: MachinePresence) throws {
    for var row in db.rows(MachineFileOperation.all) {
      if try resetFileWorker(&row) { continue }
      if row.flights.keys.contains(where: { if case .fileInput = $0 { true } else { false } }), buffers.pending(row.request.operation) == nil {
        try failFile(&row, .outcomeUnknown)
        continue
      }
      row.flights = [:]
      if row.dispatched { row.state = "reconciling" }
      try finishFileStep(&row, presence: presence)
    }
  }

  mutating func wakeFiles(presence: MachinePresence) throws {
    for var row in db.rows(MachineFileOperation.all) {
      if try resetFileWorker(&row) { continue }
      for (purpose, flight) in row.flights where flight.due <= now {
        if purpose == .start { row.state = "reconciling"; row.flights[purpose] = nil; continue }
        var next = flight
        if next.waiting { next.waiting = false; next.due = now + next.retry; next.retry = min(2000, next.retry * 2) }
        row.flights[purpose] = next
      }
      try finishFileStep(&row, presence: presence)
    }
  }
}
