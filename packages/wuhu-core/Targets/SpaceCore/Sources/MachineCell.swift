import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Cell
public struct MachineCell {
  public static let schema = [
    "CREATE INDEX machine_operations_live ON machine_operations(owner, state) WHERE state != 'retired'",
    "CREATE INDEX machine_operations_operation ON machine_operations(operation, owner)",
    "CREATE INDEX machine_operations_caller_tool ON machine_operations(caller, toolCall)",
    "CREATE INDEX machine_operations_live_tool ON machine_operations(caller, toolCall) WHERE state != 'retired'",
    "CREATE INDEX machine_operations_live_script ON machine_operations(caller, script) WHERE state != 'retired'",
  ]

  public static let owned = ["machine_presence": "owner", "machine_descriptions": "owner", "machine_operations": "owner", "machine_file_operations": "owner"]

  public mutating func reserve(_ request: MachineExec) throws -> String {
    let p = try ensurePresence()
    if p.state == "deleted" { throw deleted }
    if let refusal = invalidInput(request) { throw refusal }
    if let existing = operation(request.id) {
      guard existing.request == request else { throw OperationError(.invocationConflict) }
      return existing.id
    }
    try save(MachineOperation(id: request.id, request: request, created: now))
    return request.id
  }

  public mutating func start(_ request: MachineExec, finished: Recipient<MachineExecReply>) throws {
    let p = try ensurePresence()
    if p.state == "deleted" {
      ctx.send(.finished(.init(id: request.id, status: nil, error: deleted, tail: Data(), cursor: 0, cut: false, timedOut: nil)), to: finished)
      return
    }
    if let row = operation(request.id) {
      precondition(row.request == request && row.recipient == finished)
      return
    }
    var row = MachineOperation(id: request.id, request: request, recipient: finished, created: now)
    row.opened = true
    if let refusal = invalidInput(request) ?? admission(box) { try finish(&row, error: refusal) }
    if !row.terminal { row.stopAt = request.timeout.map { now + Int64(min($0, 1e9) * 1000) } }
    try finishExecStep(&row, presence: p)
  }

  public mutating func stop(_ exec: String, reason: String = "callerCancelled") throws {
    // Deletion can remove the operation before its waiter's acknowledgment arrives.
    let p = presence
    if p.state == "deleted" { return }
    var row = operation(exec)!
    if row.terminal || row.delivered { return }
    try requestStop(&row, reason: reason)
    try finishExecStep(&row, presence: p)
  }

  public mutating func abandon(_ exec: String) throws {
    let p = presence
    if p.state == "deleted" { return }
    var row = operation(exec)!
    row.recipient = nil
    row.background = false
    row.tail = Data()
    if !row.terminal && !row.delivered { try requestStop(&row, reason: "callerCancelled") }
    try finishExecStep(&row, presence: p)
  }

  public mutating func taken(_ exec: String) throws {
    let p = presence
    if p.state == "deleted" { return }
    var row = operation(exec)!
    precondition(row.delivered && row.recipient != nil && !row.background)
    row.recipient = nil
    row.tail = Data()
    try finishExecStep(&row, presence: p)
  }

  public mutating func detach(_ exec: String) throws {
    let p = presence
    if p.state == "deleted" { return }
    var row = operation(exec)!
    precondition(row.recipient != nil && !row.background && row.request.session != nil)
    row.recipient = nil
    row.background = true
    if row.delivered {
      row.delivered = false
      try deliver(&row)
    }
    try finishExecStep(&row, presence: p)
  }

  public mutating func background(_ exec: String) throws {
    let p = presence
    if p.state == "deleted" { return }
    var row = operation(exec)!
    guard row.request.script == nil else { throw OperationError(.invalidInput, message: "a script process cannot outlive its script") }
    precondition(row.request.session != nil)
    row.background = true
    if row.terminal { try deliver(&row) }
    try finishExecStep(&row, presence: p)
  }

  public mutating func closeBoxes() {
    for socket in ctx.sockets(of: BoxSocket.self) { socket.close() }
    for socket in ctx.sockets(of: FileBulk.self) { socket.close() }
  }

  public mutating func delete() throws {
    var p = try ensurePresence()
    for var row in db.rows(MachineOperation.live) {
      try finish(&row, error: deleted)
    }
    for var row in db.rows(MachineFileOperation.all) { try failFile(&row, .operation(deleted), cleanup: false) }
    try db.execute(MachineFileOperation.delete())
    for socket in ctx.sockets(of: FileBulk.self) { socket.close() }
    try db.execute(MachineOperation.delete())
    p.state = "deleted"; p.lease = nil; p.describeAt = nil; p.describeDeadline = nil
    try save(p)
    for socket in ctx.sockets(of: BoxSocket.self) { socket.close() }
    for socket in ctx.sockets(of: ExecStream.self) { socket.close() }
  }

  public mutating func attached(_ socket: SocketHandle<BoxSocket>) throws { try attachBox(socket) }
  public mutating func receive(_ frame: BoxSocket.Incoming, from socket: SocketHandle<BoxSocket>) throws { try answer(frame, from: socket) }
  public mutating func closed(_ socket: SocketHandle<BoxSocket>) throws { try closeBox(socket) }
  public mutating func attached(_ socket: SocketHandle<ExecStream>) throws { try openStream(socket) }
  public mutating func receive(_ frame: ExecStream.Incoming, from socket: SocketHandle<ExecStream>) throws { try stream(frame, from: socket) }
  public mutating func closed(_ socket: SocketHandle<ExecStream>) throws { try closeStream(socket) }

  public mutating func attached(_ socket: SocketHandle<FileBulk>) throws { try openFile(socket) }
  public mutating func receive(_ frame: FileBulk.Incoming, from socket: SocketHandle<FileBulk>) throws { try receiveFile(frame, from: socket) }
  public mutating func closed(_ socket: SocketHandle<FileBulk>) throws { try closeFile(socket) }

  public func nextWake() -> Instant? {
    var deadlines: [Int64] = []
    if let p = db.rows(MachinePresence.all.select {
      MachinePresenceDeadlines.Columns(lease: $0.lease, describeAt: $0.describeAt, describeDeadline: $0.describeDeadline)
    }).first {
      deadlines += [p.lease, p.describeAt, p.describeDeadline].compactMap { $0 }
    }
    for row in db.rows(MachineOperation.live.select {
      MachineOperationDeadlines.Columns(opened: $0.opened, created: $0.created, stopAt: $0.stopAt, answerAt: $0.answerAt, flights: $0.flights)
    }) {
      if !row.opened { deadlines.append(row.created + 60000) }
      deadlines += [row.stopAt, row.answerAt].compactMap { $0 }
      deadlines += row.flights.values.filter { $0.waiting || $0.due > now }.map(\.due)
    }
    for flights in db.rows(MachineFileOperation.all.select { $0.flights }) {
      deadlines += flights.values.filter { $0.waiting || $0.due > now }.map(\.due)
    }
    return deadlines.min().map { Instant(milliseconds: $0) }
  }

  public mutating func wake() throws {
    let before = try ensurePresence()
    var p = before
    if box == nil { p.describeAt = nil; p.describeDeadline = nil }
    if let lease = p.lease, lease <= now {
      p.state = "lost"; p.lease = nil; p.describeAt = nil; p.describeDeadline = nil
      for socket in ctx.sockets(of: BoxSocket.self) { socket.close() }
      for var row in db.rows(MachineFileOperation.all) { try failFile(&row, lostFile(row), cleanup: false) }
      for var row in db.rows(MachineOperation.live.where { $0.opened }) {
        try stopOrphanStream(&row)
        try finish(&row, error: OperationError(.unknownOperation, message: "Machine was silent for the operation's lease", details: ["outcome": "unknown", "reason": "leaseSilence"]))
        try finishExecStep(&row, presence: p)
      }
    }
    if let deadline = p.describeDeadline, deadline <= now {
      p.describeDeadline = nil; p.describeAt = now + p.describeRetry; p.describeRetry = min(2000, p.describeRetry * 2)
    }
    if let box { requestDescribe(&p, to: box) }
    if p != before { try save(p) }
    try wakeFiles(presence: p)
    for var row in db.rows(MachineOperation.live) {
      try stopOrphanStream(&row)
      if !row.opened, row.created + 60000 <= now { try finish(&row, error: OperationError(.operationEnded, message: "Unopened exec was reaped")) }
      if let stopAt = row.stopAt, stopAt <= now, !row.terminal {
        if !row.dispatched {
          row.stop = "timeout"
          try finish(&row, error: OperationError(.requestDeadline, message: "Machine exec timed out before dispatch"))
          try finishExecStep(&row, presence: p)
          continue
        }
        row.stopAt = nil; row.answerAt = stopAt + 30000
        row.stop = row.stop ?? "timeout"; row.state = "stopping"; row.flights[.control] = nil
      }
      if let answerAt = row.answerAt, answerAt <= now {
        try finish(&row, error: OperationError(.requestDeadline, message: "Machine exec did not end within 30 s of its timeout stop"))
      }
      for (purpose, flight) in row.flights where flight.due <= now {
        var next = flight
        if purpose == .start { row.state = "reconciling"; row.flights[purpose] = nil; continue }
        if flight.waiting { next.waiting = false; next.due = now + flight.retry; next.retry = min(2000, flight.retry * 2) }
        row.flights[purpose] = next
      }
      try finishExecStep(&row, presence: p)
    }
  }

  public mutating func around(_ call: (inout Self) throws -> Void) throws {
    try call(&self)
    try drive()
  }

  public func tail(_ exec: String) -> Data { operation(exec)?.tail ?? Data() }

  func invalidInput(_ request: MachineExec) -> OperationError? {
    if let timeout = request.timeout, timeout <= 0 || !timeout.isFinite {
      return OperationError(.invalidInput, message: "Exec timeout must be positive and finite")
    }
    return nil
  }

  func admission(_ box: SocketHandle<BoxSocket>?) -> OperationError? {
    guard let box else { return OperationError(.machineUnavailable, message: "Machine is not attached") }
    let live = db.rows(MachineOperation.live.where { $0.dispatched }.asSelect().count()).first!
    return live * 3 + dispatchedFileStreams + 3 > box.opening.streams - 2 ? OperationError(.capacityExceeded, message: "Machine exec tunnel capacity is full") : nil
  }

  var now: Int64 { ctx.now.milliseconds }
  var presence: MachinePresence { db.rows(MachinePresence.all).first! }

  var machineDescription: MachineDescription? { db.rows(MachineDescriptionRow.all).first?.description }

  var buffers: MachineBuffers { ctx.dependency(MachineBuffers.self) }
  var box: SocketHandle<BoxSocket>? { ctx.sockets(of: BoxSocket.self).last }
  var deleted: OperationError { OperationError(.unknownMachine, message: "Machine was deleted") }
  func operation(_ exec: String) -> MachineOperation? { db.rows(MachineOperation.where { $0.id.eq(exec) }).first }
}

extension MachineCell {
  @discardableResult mutating func ensurePresence() throws -> MachinePresence {
    if let p = db.rows(MachinePresence.all).first { return p }
    let p = MachinePresence()
    try save(p)
    return p
  }

  mutating func requestStop(_ row: inout MachineOperation, reason: String) throws {
    precondition(!row.terminal && !row.delivered)
    if row.stop == nil { row.stop = reason }
    if !row.dispatched { try finish(&row, error: OperationError(.requestCancelled, message: reason)) }
    else { row.state = "stopping"; row.flights[.control] = nil }
  }

  mutating func save(_ p: MachinePresence) throws {
    try db.execute(MachinePresence.delete())
    try db.execute(MachinePresence.insert { p })
  }

  mutating func save(_ description: MachineDescriptionRow) throws {
    try db.execute(MachineDescriptionRow.delete())
    try db.execute(MachineDescriptionRow.insert { description })
  }

  mutating func save(_ value: MachineOperation) throws {
    var row = value
    row.operation = row.request.operation.uuidString.lowercased()
    row.caller = row.request.caller
    row.toolCall = row.request.toolCall?.rawValue
    row.script = row.request.script
    try db.execute(MachineOperation.where { $0.id.eq(row.id) }.delete())
    try db.execute(MachineOperation.insert { row })
  }
}
