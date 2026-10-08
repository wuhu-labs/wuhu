import enum Credentials.SecretError
import struct Credentials.SpaceSecretStores
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
  case machineLost(MachineID)
  case execNotFound(ExecID)
  case severed
  case frameTooLarge
}

public actor MachineHub {
  private struct Leg {
    let send: @Sendable ([UInt8]) async throws -> Void
    let close: @Sendable () -> Void
    let abort: @Sendable () -> Void
    var groupSecrets: Bool = false
  }

  private enum TimerKind {
    case callerGone(ExecID, generation: Int)
    case refusalExpired(ExecID)
    case machineGone(MachineID, generation: Int)
    case drainStalled(ExecID, generation: Int)
    case machineSilent(MachineID)
    case probeMachine(MachineID, generation: Int)
  }

  private let space: Space
  private let clock: any Clock<Duration>
  private let callerGrace: Duration
  private let machineGrace: Duration
  private let keyRecheck: Duration
  private let tokens: ExecTokens?
  private let secrets: SpaceSecretStores?
  private let date: DateGenerator
  private let logger: Logger = Logger(label: "wuhu.machine-hub")

  private var machineLegs: [MachineID: Leg] = [:]
  private var machineSilence: [MachineID: @Sendable () -> Duration] = [:]
  private var machineProbes: [MachineID: Int] = [:]
  private var lastMachineOpcode: [MachineID: Opcode] = [:]
  private var machineGenerations: [MachineID: Int] = [:]
  private var callerLegs: [ExecID: Leg] = [:]
  private var nextCallerGeneration: Int = 0
  private var callerGenerations: [ExecID: Int] = [:]
  private var callerStreamIDs: [ExecID: Int] = [:]
  private var callerMachines: [ExecID: MachineID] = [:]
  private var exitDelivered: Set<ExecID> = []
  private var execsByStream: [MachineID: [Int: ExecID]] = [:]
  private var machineStreamIDs: [ExecID: Int] = [:]
  // Execs the hub failed before spawning, with the stderr line their caller
  // gets again should it replay the start.
  private struct RefusalResult {
    let line: [UInt8]
    let elapsed: @Sendable () -> Duration
  }

  private var refusals: [ExecID: RefusalResult] = [:]
  // The secret values each exec's first relayed start carried, for the
  // exec's lifetime: a replay reuses them, so a running exec never changes
  // group and is never refused late.
  private var relayedSecrets: [ExecID: StringMap?] = [:]

  func retainsExec(_ id: ExecID) -> Bool {
    callerGenerations[id] != nil || callerStreamIDs[id] != nil || callerMachines[id] != nil
      || machineStreamIDs[id] != nil || exitDelivered.contains(id) || refusals[id] != nil
      || relayedSecrets[id] != nil || execsByStream.values.contains { $0.values.contains(id) }
  }

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

  // With tokens, a session's exec start carries its credential; with secrets,
  // an exec's `secrets` resolve in its machine's group. Only `serve()` and the
  // package's tests pass them.
  package init(
    space: Space,
    callerGrace: Duration = .seconds(60),
    machineGrace: Duration = .seconds(60),
    keyRecheck: Duration = .seconds(30),
    tokens: ExecTokens?,
    secrets: SpaceSecretStores? = nil,
  ) {
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    self.space = space
    self.tokens = tokens
    self.secrets = secrets
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
          let delay = await self.remainingDelay(timer.delay, for: timer.kind)
          try? await self.clock.sleep(for: delay)
          guard !Task.isCancelled else { return }
          await self.fire(timer.kind)
        }
      }
    }
  }

  // MARK: - Sessions

  /// `capabilities` are what the agent announced when it dialed
  /// (`MachineConnect.capabilitiesHeader`).
  public func runMachineSession(_ machine: MachineID, pubkey: String, capabilities: Set<String>, socket: WebSocket) async {
    let generation = bindMachine(machine, socket: socket, groupSecrets: capabilities.contains(MachineConnect.groupSecrets))
    await deliverPendingKills(machine)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.enforceLiveKey(machine, pubkey: pubkey, socket: socket) }
      for await message in socket.inbound {
        await routeFromMachine(machine, generation: generation, frameBytes(message))
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
    if record.terminal == nil, let current = try? await space.execRecord(record.id), current.terminal == .machineLost {
      await failCaller(record.id, machine: record.machine)
    }
    for await message in socket.inbound {
      guard callerGenerations[record.id] == generation else { break }
      await routeFromCaller(record, frameBytes(message))
    }
    await unbindCaller(record.id, generation: generation)
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
    await forgetTerminal(id)
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
  private func bindMachine(_ machine: MachineID, socket: WebSocket, groupSecrets: Bool) -> Int {
    machineLegs[machine]?.close()
    failPendingRequests(for: machine, with: MachineHubError.severed)
    machineGenerations[machine, default: 0] += 1
    if machineSilence[machine] == nil {
      machineSilence[machine] = elapsedSinceNow(clock)
      timersContinuation.yield((machineGrace, .machineSilent(machine)))
    }
    machineProbes[machine] = nil
    timersContinuation.yield((machineGrace / 3, .probeMachine(machine, generation: machineGenerations[machine, default: 0])))
    logger.info("machine bound", metadata: machineMetadata(machine))
    machineLegs[machine] = Leg(send: { try await socket.send(.binary($0)) }, close: { socket.close() }, abort: { socket.abort() }, groupSecrets: groupSecrets)
    return machineGenerations[machine, default: 0]
  }

  private func unbindMachine(_ machine: MachineID, generation: Int) {
    guard machineGenerations[machine] == generation else { return }
    logger.info("machine unbound", metadata: machineMetadata(machine))
    machineLegs[machine] = nil
    machineProbes[machine] = nil
    failPendingRequests(for: machine, with: MachineHubError.severed)
    timersContinuation.yield((machineGrace, .machineGone(machine, generation: generation)))
  }

  private func bindCaller(_ record: ExecRecord, socket: WebSocket) -> Int {
    remember(record)
    callerLegs[record.id]?.close()
    nextCallerGeneration += 1
    callerGenerations[record.id] = nextCallerGeneration
    callerLegs[record.id] = Leg(send: { try await socket.send(.binary($0)) }, close: { socket.close() }, abort: { socket.abort() })
    callerMachines[record.id] = record.machine
    callerStreamIDs[record.id] = nil
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

  private func unbindCaller(_ id: ExecID, generation: Int) async {
    guard callerGenerations[id] == generation else { return }
    callerLegs[id] = nil
    let forgotten = await forgetTerminal(id)
    timersContinuation.yield((callerGrace, .callerGone(id, generation: forgotten ? 0 : generation)))
  }

  private func remember(_ record: ExecRecord) {
    execsByStream[record.machine, default: [:]][record.streamID] = record.id
    machineStreamIDs[record.id] = record.streamID
    callerMachines[record.id] = record.machine
  }

  @discardableResult
  private func forgetTerminal(_ id: ExecID) async -> Bool {
    guard callerLegs[id] == nil,
          let record = try? await space.execRecord(id), record.terminal != nil,
          callerLegs[id] == nil else { return false }
    callerGenerations[id] = nil
    callerStreamIDs[id] = nil
    callerMachines[id] = nil
    machineStreamIDs[id] = nil
    execsByStream[record.machine]?[record.streamID] = nil
    if execsByStream[record.machine]?.isEmpty == true { execsByStream[record.machine] = nil }
    exitDelivered.remove(id)
    relayedSecrets[id] = nil
    return true
  }

  // MARK: - Grace timers

  private func remainingDelay(_ delay: Duration, for kind: TimerKind) -> Duration {
    if case let .machineSilent(machine) = kind, let elapsed = machineSilence[machine] {
      return max(.zero, machineGrace - elapsed())
    }
    if case let .refusalExpired(id) = kind, let refusal = refusals[id] {
      return max(.zero, .seconds(600) - refusal.elapsed())
    }
    return delay
  }

  private func fire(_ kind: TimerKind) async {
    switch kind {
    case let .refusalExpired(id):
      refusals[id] = nil
    // The rejoin deadline: a caller absent past callerGrace gets its exec
    // reaped by policy; the machine buffers output to termination, so a late
    // retry drains the tail and reads the honest reap verdict in the registry.
    // A machine-lost exec whose caller is gone too has nobody left to resume
    // it: it gets the kill, now or on the machine's next connect.
    case let .callerGone(id, generation):
      guard callerGenerations[id, default: 0] == generation, callerLegs[id] == nil else { return }
      relayedSecrets[id] = nil
      guard let record = try? await space.execRecord(id) else { return }
      await forgetTerminal(id)
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
      await forgetTerminal(id)
    case let .machineGone(machine, generation):
      guard machineGenerations[machine, default: 0] == generation, machineLegs[machine] == nil else { return }
      await failMachineCallers(machine)
    case let .machineSilent(machine):
      guard let elapsed = machineSilence[machine] else { return }
      let silence = elapsed()
      if silence < machineGrace {
        timersContinuation.yield((machineGrace - silence, .machineSilent(machine)))
        return
      }
      logger.error("machine silence deadline expired; remote process outcomes unknown", metadata: machineMetadata(machine))
      machineSilence[machine] = nil
      lastMachineOpcode[machine] = nil
      machineProbes[machine] = nil
      let leg = machineLegs.removeValue(forKey: machine)
      machineGenerations[machine, default: 0] += 1
      failPendingRequests(for: machine, with: MachineHubError.machineLost(machine))
      leg?.abort()
      await failMachineCallers(machine)
    case let .probeMachine(machine, generation):
      guard machineGenerations[machine] == generation, let leg = machineLegs[machine] else { return }
      timersContinuation.yield((machineGrace / 3, .probeMachine(machine, generation: generation)))
      guard machineProbes[machine] == nil else { return }
      let id = nextRequestID
      nextRequestID += 1
      machineProbes[machine] = id
      // Installed agents already answer stat; ping has no reply on older agents.
      let request = VFSRequest(id: id, op: .stat(path: "/"))
      try? await leg.send(FrameCodec.encode(Frame(streamID: 0, opcode: .vfsRequest, payload: request)))
    case let .drainStalled(id, generation):
      guard callerGenerations[id, default: 0] == generation, let leg = callerLegs[id], !exitDelivered.contains(id) else { return }
      let error = MachineError(code: .execNotFound, message: "exec \(id.rawValue) is finished and its stream is no longer replayable")
      try? await leg.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.error(error: error))))
      leg.close()
    }
  }

  private func elapsedSinceNow<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
  }

  private func machineMetadata(_ machine: MachineID) -> Logger.Metadata {
    [
      "machine": .string(machine.rawValue),
      "generation": .stringConvertible(machineGenerations[machine, default: 0]),
      "silence": .stringConvertible(machineSilence[machine]?() ?? .zero),
      "lastOpcode": .string(lastMachineOpcode[machine].map { String(describing: $0) } ?? "none"),
      "probeOutstanding": .stringConvertible(machineProbes[machine] != nil),
      "pendingRequests": .stringConvertible(pendingMachines.values.filter { $0 == machine }.count),
      "callers": .stringConvertible(callerMachines.filter { $0.value == machine && callerLegs[$0.key] != nil }.count),
    ]
  }

  private func failMachineCallers(_ machine: MachineID) async {
    let ids = callerLegs.keys.filter { callerMachines[$0] == machine }
    for id in ids {
      if let record = try? await space.execRecord(id), record.terminal == nil {
        try? await space.finishExec(id, .machineLost)
      }
    }
    await withTaskGroup(of: Void.self) { group in
      for id in ids {
        group.addTask { await self.failCaller(id, machine: machine) }
      }
    }
  }

  private func failCaller(_ id: ExecID, machine: MachineID) async {
    let terminal = try? await space.execRecord(id)?.terminal
    guard let leg = callerLegs[id] else { return }
    let error: MachineError
    if let terminal, terminal != .machineLost {
      error = MachineError(code: .execNotFound, message: "exec \(id.rawValue) is finished and its stream is no longer replayable")
    } else {
      error = MachineError(code: .machineLost, message: "machine \(machine.rawValue) stopped responding; remote process outcome is unknown")
    }
    let frame = FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.error(error: error)))
    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await leg.send(frame) }
      group.addTask {
        try? await self.clock.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        leg.abort()
      }
      _ = await group.next()
      leg.abort()
      callerLegs[id]?.abort()
      group.cancelAll()
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
    // Replay needs the caller's stream mapping; its hello precedes that mapping.
    guard frame.streamID != 0 else { return }
    switch frame.opcode {
    case .execStart:
      guard let start = try? frame.payload(ExecStart.self), start.id == record.id else { return }
      // Recorded even while the machine leg is absent: when the machine later
      // rebinds, its bind-time replay must already find this caller mapped, or
      // the replay is dropped and the exec ack-starves (caller-first double
      // sever).
      let firstStart = callerStreamIDs[record.id] == nil
      callerStreamIDs[record.id] = frame.streamID
      if firstStart, let leg = machineLegs[record.machine] {
        let hello = ControlMessage.hello(protocolVersion: 1, execs: [record.id])
        try? await leg.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: hello)))
      }
      if refusals[record.id] != nil {
        await deliverRefusal(record.id)
        return
      }
      // Registry re-check before relaying: a start replayed for a finished
      // exec would respawn the command on an agent that restarted and lost
      // its per-id dedup state.
      guard let current = try? await space.execRecord(record.id), current.terminal == nil else { return }
      try? await space.recordExecCommand(record.id, command: start.command.joined(separator: " "))
      guard let leg = machineLegs[record.machine] else { return }
      let values: StringMap?
      if let first = relayedSecrets[record.id] {
        values = first
      } else {
        switch await secretValues(start, machine: record.machine, groupSecrets: leg.groupSecrets) {
        case let .success(resolved): values = resolved
        case let .failure(refusal):
          await refuse(record.id, refusal.message)
          return
        }
        relayedSecrets[record.id] = .some(values)
      }
      let relayed = machineStart(start, record: record, groupSecrets: leg.groupSecrets, values: values)
      try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: frame.opcode, payload: relayed)))
      // A kill that landed while this start was in flight reached the machine
      // first, where an unknown stream drops it; repeat it behind the start.
      if let after = try? await space.execRecord(record.id), after.terminal != nil {
        try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: .kill, payload: Kill(id: record.id))))
      }
    case .stdin, .stdinEof, .ack, .kill:
      if frame.opcode == .ack, callerStreamIDs[record.id] == nil,
         let ack = try? frame.payload(Ack.self), ack.id == record.id, ack.terminal == true
      {
        callerStreamIDs[record.id] = frame.streamID
      }
      guard frame.streamID == callerStreamIDs[record.id] else { return }
      if frame.opcode == .ack, let refusal = refusals[record.id],
         let ack = try? frame.payload(Ack.self), ack.id == record.id,
         ack.terminal == true, ack.cursor == refusal.line.count
      {
        refusals[record.id] = nil
        return
      }
      guard let leg = machineLegs[record.machine] else { return }
      try? await leg.send(FrameCodec.encode(Frame(streamID: record.streamID, opcode: frame.opcode, body: frame.body)))
    default:
      return
    }
  }

  private struct ExecRefusal: Error {
    let message: String
  }

  // The start the machine gets. The server owns the session names in every
  // start it relays: whatever the caller put under them goes, and a session's
  // exec gets its credential. An agent that announced group secrets gets the
  // values resolved for the exec's first relay; an older one gets the names
  // and resolves them from its own vault.
  private func machineStart(_ start: ExecStart, record: ExecRecord, groupSecrets: Bool, values: StringMap?) -> ExecStart {
    let names = Self.secretNames(start)
    let unresolved = values == nil && !(names?.entries.isEmpty ?? true)
    let session: ExecSessionCredential? = if let caller = record.caller, let tokens {
      tokens.credential(session: SessionID(rawValue: caller), exec: start.id, timeout: start.timeout, now: date.now)
    } else {
      nil
    }
    return ExecStart(
      id: start.id,
      cwd: start.cwd,
      command: start.command,
      env: Self.withoutReserved(start.env),
      secrets: groupSecrets && !unresolved ? nil : names,
      secretValues: groupSecrets ? values : nil,
      window: start.window,
      maxOutput: start.maxOutput,
      timeout: start.timeout,
      session: session,
    )
  }

  private static func withoutReserved(_ map: StringMap?) -> StringMap? {
    map.map { StringMap($0.entries.filter { !SessionExecEnvironment.reserved.contains($0.key) }) }
  }

  private static func secretNames(_ start: ExecStart) -> StringMap? {
    withoutReserved(start.secrets)
  }

  // The values of the machine's group as it stands now, for an agent that
  // announced group secrets; nil when there is nothing to resolve.
  private func secretValues(_ start: ExecStart, machine: MachineID, groupSecrets: Bool) async -> Result<StringMap?, ExecRefusal> {
    guard groupSecrets, let names = Self.secretNames(start), !names.entries.isEmpty else { return .success(nil) }
    return await secretValues(names.entries, machine: machine).map { StringMap($0) }
  }

  // Names resolve in alphabetical order, so the one a refusal names is stable.
  private func secretValues(_ names: [String: String], machine: MachineID) async -> Result<[String: String], ExecRefusal> {
    guard let group = try? await space.machine(machine)?.group else {
      return .failure(ExecRefusal(message: "machine \(machine.rawValue) is no longer enrolled"))
    }
    guard let secrets, let store = try? secrets.group(group.rawValue) else {
      return .failure(ExecRefusal(message: "this server keeps no group secrets, so none reach machine \(machine.rawValue)"))
    }
    var values: [String: String] = [:]
    for (variable, name) in names.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
      do {
        values[variable] = try await store.value(of: name)
      } catch SecretError.unknown {
        return .failure(ExecRefusal(message: "no secret \(name) in group \(group.rawValue)"))
      } catch {
        return .failure(ExecRefusal(message: "the secrets of group \(group.rawValue) are unreadable"))
      }
    }
    return .success(values)
  }

  // A refused exec fails the way one the machine cannot spawn does: one
  // `wuhu:` line on stderr, then exit 127. Nothing reaches the machine.
  private func refuse(_ id: ExecID, _ message: String) async {
    refusals[id] = RefusalResult(line: Array("wuhu: \(message)\n".utf8), elapsed: elapsedSinceNow(clock))
    timersContinuation.yield((.seconds(600), .refusalExpired(id)))
    try? await space.finishExec(id, .exited(code: 127))
    await deliverRefusal(id)
  }

  private func deliverRefusal(_ id: ExecID) async {
    guard let refusal = refusals[id], let leg = callerLegs[id], let streamID = callerStreamIDs[id] else { return }
    let line = refusal.line
    let output = OutputChunk(id: id, stream: .stderr, cursor: 0, data: Base64Data(line))
    let exit = ExecExit(id: id, cursor: line.count, status: .exited(code: 127))
    try? await leg.send(FrameCodec.encode(Frame(streamID: streamID, opcode: .output, payload: output)))
    try? await leg.send(FrameCodec.encode(Frame(streamID: streamID, opcode: .execExit, payload: exit)))
    if callerLegs[id] != nil { exitDelivered.insert(id) }
    await forgetTerminal(id)
  }

  private func routeFromMachine(_ machine: MachineID, generation: Int, _ bytes: [UInt8]) async {
    guard machineGenerations[machine] == generation, machineLegs[machine] != nil,
          let frame = try? FrameCodec.decode(bytes) else { return }
    machineSilence[machine] = elapsedSinceNow(clock)
    lastMachineOpcode[machine] = frame.opcode
    if frame.streamID == 0 {
      await routeMachineControl(machine, frame, bytes: bytes)
      return
    }
    guard let id = await execID(machine: machine, streamID: frame.streamID) else { return }
    if frame.opcode == .execExit, let exit = try? frame.payload(ExecExit.self) {
      tokens?.revoke(id)
      relayedSecrets[id] = nil
      switch exit.status {
      case let .exited(code): try? await space.finishExec(id, .exited(code: code))
      case let .signaled(signal): try? await space.finishExec(id, .signaled(signal: signal))
      }
    }
    guard let leg = callerLegs[id], let callerStreamID = callerStreamIDs[id] else {
      await forgetTerminal(id)
      return
    }
    try? await leg.send(FrameCodec.encode(Frame(streamID: callerStreamID, opcode: frame.opcode, body: frame.body)))
    if frame.opcode == .execExit {
      if callerLegs[id] != nil { exitDelivered.insert(id) }
      await forgetTerminal(id)
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
    case .vfsResponse, .searchResponse:
      guard let id = requestID(of: frame) else { return }
      if machineProbes[machine] == id {
        machineProbes[machine] = nil
        return
      }
      guard pendingMachines[id] == machine, let continuation = pendingRequests.removeValue(forKey: id) else { return }
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
    if record.terminal == nil || callerLegs[record.id] != nil { remember(record) }
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
