import enum MachineContract.ExecEvent
import struct MachineContract.ExecID
import enum MachineContract.ExecOutputStream
import enum MachineContract.ExitStatus
import struct MachineContract.MachineID
import struct MainHub.ScriptError
import SessionDomain
import SpaceClient
import SpaceCore
import Synchronization

// Each process may hold this much output its script has not taken: the agent
// stops sending (and the process stalls on its pipes) until the script reads.
let scriptProcessWindow = 1 << 20
let scriptProcessLimit = 8

// The processes one run_script execution started. They live exactly as long as
// the execution: `shutdown` kills every exec the script minted, then the
// drivers stop.
final class ScriptProcesses: Sendable {
  fileprivate struct State {
    var processes: [ExecID: ScriptProcess] = [:]
    var starting = 0
    var minted: [ExecID] = []
    var closed = false
  }

  private let state = Mutex(State())
  private let launches: AsyncStream<ScriptProcess>
  private let launch: AsyncStream<ScriptProcess>.Continuation

  init() {
    (launches, launch) = AsyncStream.makeStream()
  }

  func run() async {
    await withDiscardingTaskGroup { group in
      for await process in launches {
        group.addTask { await process.drive() }
      }
      group.cancelAll()
    }
  }

  // Holds one of the script's process slots until `settle`.
  func admit() throws {
    try state.withLock { state in
      let running = state.processes.values.count { !$0.ended } + state.starting
      guard running < scriptProcessLimit else {
        throw ScriptError(
          "a script runs at most \(scriptProcessLimit) machine processes at once; wait for one to exit or kill it first",
        )
      }
      state.starting += 1
    }
  }

  func settle(_ process: ScriptProcess?) {
    state.withLock { state in
      state.starting -= 1
      if let process { state.processes[process.id] = process }
    }
    if let process { launch.yield(process) }
  }

  // Records an exec the script minted; false once the script has shut down,
  // when the caller must kill it itself.
  func minted(_ id: ExecID) -> Bool {
    state.withLock { state in
      guard !state.closed else { return false }
      state.minted.append(id)
      return true
    }
  }

  func process(_ id: String) throws -> ScriptProcess {
    guard let process = state.withLock({ $0.processes[ExecID(rawValue: id)] }) else {
      throw ScriptError("no process \(id) in this script")
    }
    return process
  }

  func shutdown(kill: @Sendable (ExecID) async throws -> Void) async -> [ExecID] {
    let minted = state.withLock { state in
      state.closed = true
      state.processes = [:]
      return state.minted
    }
    for id in minted {
      try? await kill(id)
    }
    launch.finish()
    return minted
  }
}

// One spawned process as its script sees it: output queued as it arrives and
// acknowledged to the machine only once the script takes it.
//
// The process holds a claim on the script's buffer budget: the whole window
// while it runs, then only the output it still buffers once it has ended, and
// nothing once its output is discarded. `giveBack` returns each shrink.
final class ScriptProcess: Sendable {
  enum End: Sendable, Equatable {
    case exited(ExitStatus)
    case lost(String)
  }

  // A line (without its newline) or a raw chunk, by the reading mode.
  struct Output: Sendable, Equatable {
    var stream: ExecOutputStream
    var bytes: [UInt8]
  }

  struct Take<Item: Sendable>: Sendable {
    var items: [Item]
    var done: Bool
  }

  fileprivate struct Chunk {
    var stream: ExecOutputStream
    var cursor: Int
    var bytes: [UInt8]
  }

  fileprivate struct Partial {
    var start: Int
    var bytes: [UInt8]
  }

  fileprivate struct State {
    var pending: [Chunk] = []
    var received = 0
    var acknowledged = 0
    var partials: [ExecOutputStream: Partial] = [:]
    var ready: [Output] = []
    var end: End?
    var stdinClosed = false
    var writes = 0
    var discarding = false
    var claimed = scriptProcessWindow
    var waiters: [AsyncStream<Void>.Continuation] = []
  }

  let id: ExecID
  let machine: MachineID
  let acceptsStdin: Bool
  private let exec: ExecSession
  private let giveBack: @Sendable (Int) -> Void
  private let state = Mutex(State())

  init(
    id: ExecID,
    machine: MachineID,
    acceptsStdin: Bool,
    exec: ExecSession,
    giveBack: @escaping @Sendable (Int) -> Void,
  ) {
    self.id = id
    self.machine = machine
    self.acceptsStdin = acceptsStdin
    self.exec = exec
    self.giveBack = giveBack
    state.withLock { $0.stdinClosed = !acceptsStdin }
  }

  var ended: Bool {
    state.withLock { $0.end != nil }
  }

  // MARK: The machine's side

  func drive() async {
    await pump()
  }

  // The caller leg, held until the exit or the script's end; output is
  // acknowledged only as the script takes it.
  private func pump() async {
    do {
      let termination = try await exec.run(
        autoAcknowledge: false, failOnRemoteError: true, input: acceptsStdin ? .caller : .closed,
        output: { _, _ in },
        onEvent: { [self] event in await received(event) },
      )
      if let reason = lostReason(termination, id: id) { finish(.lost(reason)) }
    } catch {
      if !Task.isCancelled { finish(.lost("\(error)")) }
    }
  }

  private func received(_ event: ExecEvent) async {
    switch event {
    case let .output(stream, cursor, data):
      let through = change { state -> Int? in
        state.received = cursor + data.count
        guard state.discarding else {
          state.pending.append(Chunk(stream: stream, cursor: cursor, bytes: data.bytes))
          return nil
        }
        state.acknowledged = state.received
        return state.received
      }
      if let through { await exec.acknowledge(through: through) }
    case let .exit(status):
      finish(.exited(status))
    // A failure ends the run; its message arrives as the termination.
    case .truncated, .timedOut, .failed:
      break
    }
  }

  private func finish(_ end: End) {
    change { state in
      if state.end == nil { state.end = end }
    }
  }

  @discardableResult
  private func change<Value>(_ body: (inout State) -> Value) -> Value {
    let (value, waiters, freed) = state.withLock { state in
      let value = body(&state)
      defer { state.waiters = [] }
      return (value, state.waiters, state.trimClaim())
    }
    if freed > 0 { giveBack(freed) }
    for waiter in waiters {
      waiter.yield(())
      waiter.finish()
    }
    return value
  }

  // MARK: The script's side

  // Complete lines in arrival order. A line still open holds its bytes
  // un-acknowledged; when the held bytes fill the whole window with no line
  // complete, the oldest open line is handed over as it stands, so a process
  // that never prints a newline cannot stall its reader.
  func lines() async throws -> Take<Output> {
    try await take { state in
      state.split()
      if !state.ready.isEmpty {
        defer { state.ready = [] }
        return (Take(items: state.ready, done: false), state.heldFrom)
      }
      if let end = state.end {
        let rest = state.partials.sorted { $0.value.start < $1.value.start }
          .map { Output(stream: $0.key, bytes: $0.value.bytes) }
        state.partials = [:]
        switch end {
        case .exited:
          return (Take(items: rest, done: true), state.received)
        case let .lost(reason):
          guard !rest.isEmpty else { throw lostError(reason) }
          return (Take(items: rest, done: false), state.received)
        }
      }
      guard state.received - state.heldFrom >= scriptProcessWindow,
            let oldest = state.partials.min(by: { $0.value.start < $1.value.start })
      else { return nil }
      state.partials[oldest.key] = nil
      return (Take(items: [Output(stream: oldest.key, bytes: oldest.value.bytes)], done: false), state.heldFrom)
    }
  }

  // Raw chunks in arrival order, adjacent chunks of one stream joined.
  func chunks() async throws -> Take<Output> {
    try await take { state in
      if !state.pending.isEmpty {
        var chunks: [Output] = []
        for chunk in state.pending {
          if chunks.last?.stream == chunk.stream {
            chunks[chunks.count - 1].bytes += chunk.bytes
          } else {
            chunks.append(Output(stream: chunk.stream, bytes: chunk.bytes))
          }
        }
        state.pending = []
        return (Take(items: chunks, done: false), state.received)
      }
      switch state.end {
      case .exited?: return (Take(items: [], done: true), state.received)
      case let .lost(reason)?: throw lostError(reason)
      case nil: return nil
      }
    }
  }

  func wait() async throws -> ExitStatus {
    try await take { state in
      switch state.end {
      case let .exited(status)?: return (status, nil)
      case let .lost(reason)?: throw lostError(reason)
      case nil: return nil
      }
    }
  }

  // A write waits for the machine's window, so a process that stops reading
  // holds the script, not the server's memory.
  func write(_ bytes: [UInt8]) async throws {
    guard acceptsStdin else { throw ScriptError("process \(id.rawValue) was spawned without { stdin: true }") }
    try state.withLock { state in
      guard state.end == nil else { throw ScriptError("process \(id.rawValue) has ended; stdin takes no more writes") }
      guard !state.stdinClosed else { throw ScriptError("stdin of process \(id.rawValue) is closed") }
      state.writes += 1
    }
    defer { change { $0.writes -= 1 } }
    try await exec.sendStdin(bytes)
  }

  // Closes after the writes in flight, so an unawaited write never lands on a closed stdin.
  func end() async throws {
    guard acceptsStdin else { throw ScriptError("process \(id.rawValue) was spawned without { stdin: true }") }
    let closing: Bool = try await take { state in
      guard state.writes == 0 else { return nil }
      defer { state.stdinClosed = true }
      return (!state.stdinClosed, nil)
    }
    if closing { await exec.closeStdin() }
  }

  func kill() async {
    await exec.kill()
  }

  // The reader went away before the end (it broke out, or threw): with one
  // reader per process nobody can take this output any more, so what is
  // buffered is dropped and what arrives from now on is acknowledged unread.
  // The process never stalls on its pipes and holds none of the budget.
  func discard() async {
    let through = change { state -> Int? in
      state.discarding = true
      state.pending = []
      state.partials = [:]
      state.ready = []
      guard state.received > state.acknowledged else { return nil }
      state.acknowledged = state.received
      return state.received
    }
    if let through { await exec.acknowledge(through: through) }
  }

  private func lostError(_ reason: String) -> ScriptError {
    ScriptError("process \(id.rawValue): \(reason); it gets killed if the machine comes back")
  }

  // Runs `step` until it yields a value, sleeping on the next change in
  // between; the cursor it returns is acknowledged to the machine.
  private func take<Value: Sendable>(
    _ step: (inout State) throws -> (Value, Int?)?,
  ) async throws -> Value {
    while true {
      let (signal, waiter) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let (outcome, freed) = try state.withLock { state -> ((Value, Int?)?, Int) in
        guard let outcome = try step(&state) else {
          state.waiters.append(waiter)
          return (nil, 0)
        }
        if let cursor = outcome.1, cursor > state.acknowledged {
          state.acknowledged = cursor
          return (outcome, state.trimClaim())
        }
        return ((outcome.0, nil), state.trimClaim())
      }
      if freed > 0 { giveBack(freed) }
      if let (value, cursor) = outcome {
        if let cursor { await exec.acknowledge(through: cursor) }
        return value
      }
      for await _ in signal {}
      try Task.checkCancellation()
    }
  }
}

extension ScriptProcess.State {
  // Moves every complete line out of the pending chunks into `ready`; the
  // bytes after a stream's last newline wait in its partial line.
  fileprivate mutating func split() {
    for chunk in pending {
      var rest = chunk.bytes[...]
      while let newline = rest.firstIndex(of: 0x0A) {
        let head = rest[..<newline]
        ready.append(.init(stream: chunk.stream, bytes: (partials.removeValue(forKey: chunk.stream)?.bytes ?? []) + head))
        rest = rest[(newline + 1)...]
      }
      if !rest.isEmpty {
        partials[chunk.stream, default: .init(start: chunk.cursor + rest.startIndex, bytes: [])].bytes += rest
      }
    }
    pending = []
  }

  // The first byte the script has not taken yet.
  fileprivate var heldFrom: Int {
    partials.values.map(\.start).min() ?? received
  }

  // Shrinks the budget claim to what the process can still hold, returning
  // the bytes freed: the window while it runs (the agent may send that much
  // ahead of the reader), then only what is still buffered.
  fileprivate mutating func trimClaim() -> Int {
    var needed = 0
    if !discarding, end == nil {
      needed = scriptProcessWindow
    } else if !discarding {
      for chunk in pending { needed += chunk.bytes.count }
      for partial in partials.values { needed += partial.bytes.count }
      for line in ready { needed += line.bytes.count }
    }
    let freed = max(0, claimed - needed)
    claimed -= freed
    return freed
  }
}
