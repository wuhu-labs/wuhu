import Dependencies
import JSONValue
import Logging
import MachineChannel
import MachineContract
import Serve
import SessionDomain
import SpaceCore

public enum MachineHubError: Error, Equatable, Sendable {
  case machineUnattached(MachineID)
  case execNotFound(ExecID)
  case severed
  case frameTooLarge
}

public actor MachineHub {
  private struct Leg {
    let send: @Sendable ([UInt8]) async throws -> Void
    let close: @Sendable () -> Void
  }

  private enum TimerKind {
    case callerGone(ExecID, generation: Int)
    case machineGone(MachineID, generation: Int)
    case drainStalled(ExecID, generation: Int)
  }

  private let space: Space
  private let clock: any Clock<Duration>
  private let callerGrace: Duration
  private let machineGrace: Duration
  private let keyRecheck: Duration
  private let tokens: ExecTokens?
  private let date: DateGenerator
  private let logger: Logger = Logger(label: "wuhu.machine-hub")

  private var machineLegs: [MachineID: Leg] = [:]
  private var machineGenerations: [MachineID: Int] = [:]
  private var callerLegs: [ExecID: Leg] = [:]
  private var callerGenerations: [ExecID: Int] = [:]
  private var callerStreamIDs: [ExecID: Int] = [:]
  private var callerMachines: [ExecID: MachineID] = [:]
  private var exitDelivered: Set<ExecID> = []
  private var execsByStream: [MachineID: [Int: ExecID]] = [:]
  private var machineStreamIDs: [ExecID: Int] = [:]

  private var nextRequestID: Int = 1
  private var pendingRequests: [Int: AsyncThrowingStream<Frame, any Error>.Continuation] = [:]
  private var pendingMachines: [Int: MachineID] = [:]

  private let timers: AsyncStream<(delay: Duration, kind: TimerKind)>
  private let timersContinuation: AsyncStream<(delay: Duration, kind: TimerKind)>.Continuation

  public init(
    space: Space,
    callerGrace: Duration = .seconds(60),
    machineGrace: Duration = .seconds(60),
    keyRecheck: Duration = .seconds(30),
  ) {
    self.init(space: space, callerGrace: callerGrace, machineGrace: machineGrace, keyRecheck: keyRecheck, tokens: nil)
  }

  // With tokens, a session's exec start carries its credential; only
  // `serve()` and the package's tests pass them.
  package init(
    space: Space,
    callerGrace: Duration = .seconds(60),
    machineGrace: Duration = .seconds(60),
    keyRecheck: Duration = .seconds(30),
    tokens: ExecTokens?,
  ) {
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    self.space = space
    self.tokens = tokens
    self.date = date
    self.clock = clock
    self.callerGrace = callerGrace
    self.machineGrace = machineGrace
    self.keyRecheck = keyRecheck
    (timers, timersContinuation) = AsyncStream.makeStream()
  }

  // Owns every grace timer: run this inside the server's task group. On boot,
  // live registry rows without a caller leg get a fresh caller grace, so an
  // exec orphaned across a restart can never hang live forever.
  public func run() async {
    for record in (try? await space.liveExecs()) ?? [] where callerLegs[record.id] == nil {
      remember(record)
      timersContinuation.yield((callerGrace, .callerGone(record.id, generation: callerGenerations[record.id, default: 0])))
    }
    await withDiscardingTaskGroup { group in
      for await timer in timers {
        group.addTask {
          try? await self.clock.sleep(for: timer.delay)
          guard !Task.isCancelled else { return }
          await self.fire(timer.kind)
        }
      }
    }
  }

  // MARK: - Sessions

  public func runMachineSession(_ machine: MachineID, pubkey: String, socket: WebSocket) async {
    let generation = bindMachine(machine, socket: socket)
    await deliverPendingKills(machine)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.enforceLiveKey(machine, pubkey: pubkey, socket: socket) }
      for await message in socket.inbound {
        await routeFromMachine(machine, frameBytes(message))
      }
      group.cancelAll()
    }
    unbindMachine(machine, generation: generation)
  }

  public func kickMachine(_ machine: MachineID) {
    machineLegs[machine]?.close()
  }

  // Connect-time verification alone would let a kicked key ride an already
  // open socket; this watchdog re-resolves the live key row for the whole
  // connection lifetime and severs the leg the moment it stops resolving.
  private func enforceLiveKey(_ machine: MachineID, pubkey: String, socket: WebSocket) async {
    while true {
      do {
        try await clock.sleep(for: keyRecheck)
      } catch {
        return
      }
      guard ((try? await space.machine(pubkey: pubkey)) ?? nil) == machine else {
        logger.notice("machine key no longer live; severing", metadata: ["machine": .string(machine.rawValue)])
        socket.close()
        return
      }
    }
  }

  public func runCallerSession(_ record: ExecRecord, socket: WebSocket) async {
    let generation = bindCaller(record, socket: socket)
    for await message in socket.inbound {
      await routeFromCaller(record, frameBytes(message))
    }
    unbindCaller(record.id, generation: generation)
  }

  public func noteMinted(_ record: ExecRecord) {
    remember(record)
    timersContinuation.yield((callerGrace, .callerGone(record.id, generation: callerGenerations[record.id, default: 0])))
  }

  public func attachedMachines() -> Set<MachineID> {
    Set(machineLegs.keys)
  }

  // The row turns `cancelled` before the kill frame goes out, and the real exit
  // still settles it. Recording first is what makes the kill stick: a start
  // relayed after this point is refused, and one already in flight is followed
  // by a second kill (see routeFromCaller).
  public func kill(_ id: ExecID) async throws {
    guard let record = try await space.execRecord(id) else { throw MachineHubError.execNotFound(id) }
    guard record.terminal == nil else { return }
    try await space.finishExec(id, .cancelled)
    if let leg = machineLegs[record.machine] {
      try await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: .kill, payload: Kill(id: id))))
      try await space.markKillDelivered(id)
    } else {
      // No machine will ever produce an exit event for this exec: close the
      // caller leg so a connected caller learns the outcome from the registry
      // instead of hanging.
      callerLegs[id]?.close()
    }
  }

  // MARK: - Machine round trips

  // The listener enforces this WebSocket frame ceiling; an outbound frame
  // that exceeds it would sever the machine leg on a real socket, so the hub
  // refuses to send it and the caller fails loudly instead.
  public static let maximumFrameBytes: Int = 16 << 20

  public func vfs(machine: MachineID, op: VFSOp) async throws -> VFSResult {
    let response: VFSResponse = try await roundTrip(machine, .vfsRequest) { VFSRequest(id: $0, op: op) }
    return response.result
  }

  public func search(machine: MachineID, query: SearchQuery) async throws -> SearchResult {
    let response: SearchResponse = try await roundTrip(machine, .searchRequest) { SearchRequest(id: $0, query: query) }
    return response.result
  }

  public func vaultSet(machine: MachineID, name: String, value: String) async throws -> VaultOutcome {
    try await roundTrip(machine, .vaultSet) { VaultSet(id: $0, name: name, value: value) }
  }

  public func vaultRemove(machine: MachineID, name: String) async throws -> VaultOutcome {
    try await roundTrip(machine, .vaultRemove) { VaultRemove(id: $0, name: name) }
  }

  public func vaultList(machine: MachineID) async throws -> VaultOutcome {
    try await roundTrip(machine, .vaultList) { VaultList(id: $0) }
  }

  private func roundTrip<Response: Decodable>(
    _ machine: MachineID,
    _ opcode: Opcode,
    _ payload: (Int) -> some Encodable,
  ) async throws -> Response {
    guard let leg = machineLegs[machine] else { throw MachineHubError.machineUnattached(machine) }
    let id = nextRequestID
    nextRequestID += 1
    let (frames, continuation) = AsyncThrowingStream<Frame, any Error>.makeStream()
    pendingRequests[id] = continuation
    pendingMachines[id] = machine
    do {
      let bytes = FrameCodec.encode(Frame(streamID: 0, opcode: opcode, payload: payload(id)))
      guard bytes.count <= MachineHub.maximumFrameBytes else { throw MachineHubError.frameTooLarge }
      try await leg.send(bytes)
      for try await frame in frames {
        return try frame.payload(Response.self)
      }
      throw MachineHubError.severed
    } catch {
      pendingRequests[id] = nil
      pendingMachines[id] = nil
      throw error
    }
  }

  // MARK: - Binding

  // Round trips in flight were sent on the old binding and can never be
  // answered; they fail here, at rebind, not on the machine's hello — a round
  // trip issued on the new binding races the in-flight hello frame and must
  // survive it.
  private func bindMachine(_ machine: MachineID, socket: WebSocket) -> Int {
    machineLegs[machine]?.close()
    failPendingRequests(for: machine, with: MachineHubError.severed)
    machineGenerations[machine, default: 0] += 1
    machineLegs[machine] = Leg(send: { try await socket.send(.binary($0)) }, close: { socket.close() })
    return machineGenerations[machine, default: 0]
  }

  private func unbindMachine(_ machine: MachineID, generation: Int) {
    guard machineGenerations[machine] == generation else { return }
    machineLegs[machine] = nil
    failPendingRequests(for: machine, with: MachineHubError.severed)
    timersContinuation.yield((machineGrace, .machineGone(machine, generation: generation)))
  }

  private func bindCaller(_ record: ExecRecord, socket: WebSocket) -> Int {
    remember(record)
    callerLegs[record.id]?.close()
    callerGenerations[record.id, default: 0] += 1
    callerLegs[record.id] = Leg(send: { try await socket.send(.binary($0)) }, close: { socket.close() })
    callerMachines[record.id] = record.machine
    exitDelivered.remove(record.id)
    // A caller must never wait in silence: if the machine is not attached now,
    // its absence grace runs from this bind (covers a machine that never
    // dialed in and one that stays gone after its own grace already fired).
    if machineLegs[record.machine] == nil {
      timersContinuation.yield((machineGrace, .machineGone(record.machine, generation: machineGenerations[record.machine, default: 0])))
    }
    // A terminal exec admits reconnects so the retained tail can drain
    // byte-exactly; if the exit event does not reach this binding within the
    // grace (the agent restarted and the replay state is gone), fail loudly.
    if record.terminal != nil {
      timersContinuation.yield((machineGrace, .drainStalled(record.id, generation: callerGenerations[record.id, default: 0])))
    }
    return callerGenerations[record.id, default: 0]
  }

  private func unbindCaller(_ id: ExecID, generation: Int) {
    guard callerGenerations[id] == generation else { return }
    callerLegs[id] = nil
    timersContinuation.yield((callerGrace, .callerGone(id, generation: generation)))
  }

  private func remember(_ record: ExecRecord) {
    execsByStream[record.machine, default: [:]][record.streamID] = record.id
    machineStreamIDs[record.id] = record.streamID
    callerMachines[record.id] = record.machine
  }

  // MARK: - Grace timers

  private func fire(_ kind: TimerKind) async {
    switch kind {
    // The rejoin deadline: a caller absent past callerGrace gets its exec
    // reaped by policy; the machine buffers output to termination, so a late
    // retry drains the tail and reads the honest reap verdict in the registry.
    // A machine-lost exec whose caller is gone too has nobody left to resume
    // it: it gets the kill, now or on the machine's next connect.
    case let .callerGone(id, generation):
      guard callerGenerations[id, default: 0] == generation, callerLegs[id] == nil else { return }
      guard let record = try? await space.execRecord(id) else { return }
      switch record.terminal {
      case nil:
        try? await space.finishExec(id, .reaped)
      case .machineLost where !record.killDelivered:
        break
      default:
        return
      }
      if let leg = machineLegs[record.machine] {
        try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: .kill, payload: Kill(id: id))))
        try? await space.markKillDelivered(id)
      }
    case let .machineGone(machine, generation):
      guard machineGenerations[machine, default: 0] == generation, machineLegs[machine] == nil else { return }
      let error = MachineError(code: .machineLost, message: "machine \(machine.rawValue) lost")
      let frame = FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.error(error: error)))
      for (id, leg) in callerLegs where callerMachines[id] == machine {
        guard let record = try? await space.execRecord(id), record.terminal == nil else { continue }
        try? await space.finishExec(id, .machineLost)
        try? await leg.send(frame)
        leg.close()
      }
    case let .drainStalled(id, generation):
      guard callerGenerations[id, default: 0] == generation, let leg = callerLegs[id], !exitDelivered.contains(id) else { return }
      let error = MachineError(code: .execNotFound, message: "exec \(id.rawValue) is finished and its stream is no longer replayable")
      try? await leg.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.error(error: error))))
      leg.close()
    }
  }

  // A machine-lost exec whose caller is still dialed is left alone: the caller
  // resumes it now that the machine is back.
  private func deliverPendingKills(_ machine: MachineID) async {
    guard let leg = machineLegs[machine] else { return }
    for record in (try? await space.pendingKills(machine: machine)) ?? [] {
      if record.terminal == .machineLost, callerLegs[record.id] != nil { continue }
      guard (try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: .kill, payload: Kill(id: record.id))))) != nil else { return }
      try? await space.markKillDelivered(record.id)
    }
  }

  // MARK: - Routing

  private func routeFromCaller(_ record: ExecRecord, _ bytes: [UInt8]) async {
    guard let frame = try? FrameCodec.decode(bytes) else { return }
    if frame.streamID == 0 {
      guard frame.opcode == .control, case .hello = try? frame.payload(ControlMessage.self) else { return }
      guard let leg = machineLegs[record.machine] else { return }
      try? await leg.send(bytes)
      return
    }
    switch frame.opcode {
    case .execStart:
      guard let start = try? frame.payload(ExecStart.self), start.id == record.id else { return }
      // Recorded even while the machine leg is absent: when the machine later
      // rebinds, its bind-time replay must already find this caller mapped, or
      // the replay is dropped and the exec ack-starves (caller-first double
      // sever).
      callerStreamIDs[record.id] = frame.streamID
      // Registry re-check before relaying: a start replayed for a finished
      // exec would respawn the command on an agent that restarted and lost
      // its per-id dedup state.
      guard let current = try? await space.execRecord(record.id), current.terminal == nil else { return }
      try? await space.recordExecCommand(record.id, command: start.command.joined(separator: " "))
      guard let leg = machineLegs[record.machine] else { return }
      let relayed = sessionStart(start, caller: record.caller)
      try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: frame.opcode, payload: relayed)))
      // A kill that landed while this start was in flight reached the machine
      // first, where an unknown stream drops it; repeat it behind the start.
      if let after = try? await space.execRecord(record.id), after.terminal != nil {
        try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: .kill, payload: Kill(id: record.id))))
      }
    case .stdin, .stdinEof, .ack, .kill:
      guard frame.streamID == callerStreamIDs[record.id], let leg = machineLegs[record.machine] else { return }
      try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: frame.opcode, body: frame.body)))
    default:
      return
    }
  }

  // The server owns the session names in every start it relays: whatever the
  // caller put under them goes, and a session's exec gets its credential.
  private func sessionStart(_ start: ExecStart, caller: String?) -> ExecStart {
    func stripped(_ map: StringMap?) -> StringMap? {
      map.map { StringMap($0.entries.filter { !SessionExecEnvironment.reserved.contains($0.key) }) }
    }
    let session: ExecSessionCredential? = if let caller, let tokens {
      tokens.credential(session: SessionID(rawValue: caller), exec: start.id, timeout: start.timeout, now: date.now)
    } else {
      nil
    }
    return ExecStart(
      id: start.id,
      cwd: start.cwd,
      command: start.command,
      env: stripped(start.env),
      secrets: stripped(start.secrets),
      window: start.window,
      maxOutput: start.maxOutput,
      timeout: start.timeout,
      session: session,
    )
  }

  private func routeFromMachine(_ machine: MachineID, _ bytes: [UInt8]) async {
    guard let frame = try? FrameCodec.decode(bytes) else { return }
    if frame.streamID == 0 {
      await routeMachineControl(machine, frame, bytes: bytes)
      return
    }
    guard let id = await execID(machine: machine, streamID: frame.streamID) else { return }
    if frame.opcode == .execExit, let exit = try? frame.payload(ExecExit.self) {
      tokens?.revoke(id)
      switch exit.status {
      case let .exited(code): try? await space.finishExec(id, .exited(code: code))
      case let .signaled(signal): try? await space.finishExec(id, .signaled(signal: signal))
      }
    }
    guard let leg = callerLegs[id], let callerStreamID = callerStreamIDs[id] else { return }
    try? await leg.send(FrameCodec.encode(Frame(streamID: callerStreamID, opcode: frame.opcode, body: frame.body)))
    if frame.opcode == .execExit {
      exitDelivered.insert(id)
    }
  }

  private func routeMachineControl(_ machine: MachineID, _ frame: Frame, bytes: [UInt8]) async {
    switch frame.opcode {
    case .control:
      guard let message = try? frame.payload(ControlMessage.self) else { return }
      switch message {
      case .hello:
        // The machine rebound: every caller must replay its un-acked tail (the
        // relay dropped whatever it sent into the dead leg).
        for (id, leg) in callerLegs where callerMachines[id] == machine {
          try? await leg.send(bytes)
          logger.debug("relayed machine hello", metadata: ["exec": .string(id.rawValue)])
        }
      case .ping:
        break
      case let .error(error):
        logger.warning("machine control error", metadata: ["machine": .string(machine.rawValue), "code": .string(error.code.rawValue)])
      }
    case .vfsResponse, .searchResponse, .vaultSet, .vaultRemove, .vaultList:
      guard let id = requestID(of: frame), let continuation = pendingRequests.removeValue(forKey: id) else { return }
      pendingMachines[id] = nil
      continuation.yield(frame)
      continuation.finish()
    default:
      break
    }
  }

  private func execID(machine: MachineID, streamID: Int) async -> ExecID? {
    if let id = execsByStream[machine]?[streamID] { return id }
    guard let record = try? await space.execRecord(machine: machine, streamID: streamID) else { return nil }
    remember(record)
    return record.id
  }

  private func failPendingRequests(for machine: MachineID, with error: any Error) {
    for (id, owner) in pendingMachines where owner == machine {
      pendingRequests.removeValue(forKey: id)?.finish(throwing: error)
      pendingMachines[id] = nil
    }
  }

  private func requestID(of frame: Frame) -> Int? {
    guard case let .object(fields) = frame.body, case let .integer(id)? = fields["id"] else { return nil }
    return id
  }

  private nonisolated func frameBytes(_ message: WebSocketMessage) -> [UInt8] {
    switch message {
    case let .binary(bytes): bytes
    case let .text(text): Array(text.utf8)
    }
  }
}
