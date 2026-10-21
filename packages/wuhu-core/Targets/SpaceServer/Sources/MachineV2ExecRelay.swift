import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.SpaceSecretStores
import Dependencies
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import struct OperationClient.Operation
import struct OperationClient.OperationOwner
import struct OperationClient.OutputChunk
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import struct OperationProtocol.Verdict
import Serve
import struct SessionDomain.SessionID
import SpaceCore
import Synchronization

/// One exec's relay between its caller endpoint and its machine operation. `resumed` is the operation a restart found live:
/// the relay picks it up where the store holds it instead of starting one.
struct MachineV2ExecRelay: Sendable {
  let record: ExecRecord
  let endpoint: ChannelEndpoint
  let starter: ExecStarter
  let space: Space
  let tokens: ExecTokens?
  let secrets: SpaceSecretStores?
  var resumed: ResumedExec? = nil
}

/// A live exec operation a restart found, with the relay state stored on it.
struct ResumedExec: Sendable {
  let operation: OperationClient.Operation
  let state: ExecRelayState
}

/// What the relay keeps on its operation, written with the claim, so a restart resumes the exec as it was: the actor that holds
/// it, when its timeout stops it, and, once its output was cut, the combined cursor the caller's output ends at.
struct ExecRelayState: Codable, Equatable, Sendable {
  var holder: ExecLeg
  var stopAt: Date?
  var cut: Int?

  init(holder: ExecLeg, stopAt: Date?) {
    self.holder = holder; self.stopAt = stopAt
  }

  init(_ value: JSONValue) throws {
    self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
  }

  func json() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
  }

  /// The state with the caller's output ending at `cut`, when the endpoint still has the exec.
  func cutting(at cut: Int?) -> Self {
    var next = self
    next.cut = cut
    return next
  }

  private enum CodingKeys: String, CodingKey { case session, person, anonymous, stopAt, cut }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let session = try c.decodeIfPresent(String.self, forKey: .session) {
      holder = .session(SessionID(rawValue: session))
    } else if let account = try c.decodeIfPresent(String.self, forKey: .person) {
      holder = .person(AccountID(rawValue: account))
    } else if try c.decodeIfPresent(Bool.self, forKey: .anonymous) == true {
      holder = .anonymous
    } else {
      throw DecodingError.dataCorruptedError(forKey: .anonymous, in: c, debugDescription: "Exec relay state names no holder")
    }
    stopAt = try c.decodeIfPresent(Date.self, forKey: .stopAt)
    cut = try c.decodeIfPresent(Int.self, forKey: .cut)
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch holder {
    case let .session(id): try c.encode(id.rawValue, forKey: .session)
    case let .person(account): try c.encode(account.rawValue, forKey: .person)
    case .anonymous: try c.encode(true, forKey: .anonymous)
    }
    try c.encodeIfPresent(stopAt, forKey: .stopAt)
    try c.encodeIfPresent(cut, forKey: .cut)
  }
}

extension MachineV2Service {
  static let timeoutStop = "timeout"
  // Seconds, the way the v1 agent bounds a caller's timeout: a larger Duration traps.
  static let timeoutCeiling = 1e9
  /// How long a timeout stop may take to end the process and drain its output: the supervisor's five-second SIGKILL escalation
  /// plus margin. Past it the caller is answered with an unknown status. Task-local so tests can shorten it.
  @TaskLocal static var timeoutStopGrace: Duration = .seconds(30)
  /// How long an exec waits for a caller: its first one, or one back after the last left.
  @TaskLocal static var callerGrace: Duration = .seconds(60)
  /// How long a finished exec's endpoint stays for a caller that reconnects to read its end.
  @TaskLocal static var endpointRetention: Duration = .seconds(600)

  func noteMinted(_ record: ExecRecord, space: Space) {
    relays.continuation.yield(.minted(record, space))
  }

  func expireUnconnected(_ record: ExecRecord, space: Space) async {
    @Dependency(\.continuousClock) var clock
    do { try await clock.sleep(for: Self.callerGrace) } catch { return }
    guard execEndpoints[record.id.rawValue] == nil else { return }
    killedExecs.remove(record.id.rawValue)
    try? await space.finishExec(record.id, .reaped)
  }

  /// The actor an exec's endpoint belongs to: the session that minted it, else whoever sent its start, else whoever is attached. One
  /// actor at a time, so no other actor can type into or read the exec; the owner may always reconnect.
  private func holder(_ record: ExecRecord) -> ExecLeg? {
    if let caller = record.caller { return .session(SessionID(rawValue: caller)) }
    guard let entry = execEndpoints[record.id.rawValue] else { return nil }
    return entry.starter.sender ?? entry.callers.values.first
  }

  func admits(_ record: ExecRecord, leg: ExecLeg) -> Bool {
    holder(record).map { $0 == leg } ?? true
  }

  func runCaller(_ record: ExecRecord, socket: WebSocket, leg: ExecLeg, space: Space, tokens: ExecTokens?, secrets: SpaceSecretStores?) async {
    @Dependency(\.date) var date
    let key = record.id.rawValue
    // The route refuses another actor with 409 before upgrading; this covers the race between that check and here. A group whose
    // operations are not resumed yet has no endpoint for its resumed execs: the caller comes back later.
    guard admits(record, leg: leg), recovered(record.group) else { socket.close(); return }
    // An ended exec that keeps no endpoint has nothing to say on the channel: the socket closes, and the caller reads how the
    // exec ended from its record (an exec a restart could not resume reads as machine lost).
    if execEndpoints[key] == nil, let current = try? await space.execRecord(record.id), current.terminal != nil, execEndpoints[key] == nil {
      socket.close(); return
    }
    let caller = UUID()
    if execEndpoints[key] == nil {
      // Stdin is acknowledged once durable, so a restart resumes it where the caller's acknowledgement says.
      let entry = ExecEndpoint(endpoint: ChannelEndpoint(incomingResume: .init(output: 0, stdin: 0)))
      execEndpoints[key] = entry
      relays.continuation.yield(.caller(.init(record: record, endpoint: entry.endpoint, starter: entry.starter, space: space, tokens: tokens, secrets: secrets)))
    }
    let entry = execEndpoints[key]!
    execEndpoints[key]!.callers[caller] = leg
    execEndpoints[key]!.disconnected = nil
    let socketLeg = WebSocketTransport(socket)
    let (inbound, admitted) = AsyncStream<[UInt8]>.makeStream()
    await withTaskGroup(of: Void.self) { tasks in
      tasks.addTask {
        for await bytes in socketLeg.inbound {
          guard entry.starter.admits(bytes, from: leg) else { break }
          admitted.yield(bytes)
        }
        admitted.finish()
      }
      await entry.endpoint.run(GatedLeg(inbound: inbound, base: socketLeg))
      tasks.cancelAll()
    }
    execEndpoints[key]?.callers[caller] = nil
    if execEndpoints[key]?.callers.isEmpty == true { execEndpoints[key]?.disconnected = date.now }
  }

  private func callerExpired(_ key: String) -> Bool {
    @Dependency(\.date) var date
    guard let entry = execEndpoints[key], entry.callers.isEmpty, let disconnected = entry.disconnected else { return false }
    return date.now.timeIntervalSince(disconnected) >= Double(Self.callerGrace.components.seconds)
  }

  func killExec(_ record: ExecRecord) async throws {
    killedExecs.insert(record.id.rawValue)
    guard let operation = execEndpoints[record.id.rawValue]?.operation else { return }
    try await operation.stop("callerCancelled")
    try await space.markKillDelivered(record.id)
  }

  /// Relays the exec, then keeps its endpoint `endpointRetention` for a caller that comes back to read the end.
  func serveExec(_ relay: MachineV2ExecRelay) async {
    let key = relay.record.id.rawValue
    await relayExec(relay)
    @Dependency(\.date) var date
    execEndpoints[key]?.completed = date.now
    execEndpoints[key]?.operation = nil
    killedExecs.remove(key)
    relay.tokens?.idTokens.revoke(relay.record.id)
    @Dependency(\.continuousClock) var clock
    try? await clock.sleep(for: Self.endpointRetention)
    if execEndpoints[key]?.completed != nil { execEndpoints[key] = nil }
  }

  private func relayExec(_ relay: MachineV2ExecRelay) async {
    let record = relay.record
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    var operation = relay.resumed?.operation
    var state = relay.resumed?.state
    // Fixed once, when the exec is admitted, and kept on the operation: a restart resumes the same deadline.
    var deadline = state?.stopAt.map { ExecDeadline(stopAt: $0, now: date.now, clock: clock) }
    // A resumed exec's timeout stops it whether or not its caller is back yet.
    let stopScope = TaskScope()
    let stopping = relay.resumed.flatMap { resumed in
      deadline.flatMap { deadline in
        try? stopScope.run("resumed-exec-timeout") {
          @Dependency(\.continuousClock) var clock
          do { try await clock.sleep(for: deadline.untilStop()) } catch { return }
          try? await resumed.operation.stop(Self.timeoutStop)
        }
      }
    }
    let incoming = await firstExec(relay.endpoint)
    stopping?.cancel()
    await stopScope.close()
    guard let exec = incoming else {
      guard !Task.isCancelled, !closing else { return }
      if let resumed = relay.resumed {
        try? await resumed.operation.abandon("callerGone")
        try? await relay.space.finishExec(record.id, .cancelled)
      } else {
        try? await relay.space.finishExec(record.id, .reaped)
      }
      return
    }
    let lifetime = RelayLifetime()
    // Why the operation is let go once the caller is answered: nothing left to read, or the relay failed it.
    var release = "callerGone"
    do {
      if operation == nil {
        guard let holder = holder(record) else { throw ExecRefused(message: "invalidInput: Exec start came from no caller") }
        let fresh = ExecRelayState(holder: holder, stopAt: exec.start.timeout.map { date.now.addingTimeInterval(min($0, Self.timeoutCeiling)) })
        state = fresh
        deadline = fresh.stopAt.map { ExecDeadline(stopAt: $0, now: date.now, clock: clock) }
        operation = try await start(exec, relay: relay, state: fresh)
      }
      guard let operation, let state else { return }
      if killedExecs.contains(record.id.rawValue) { try await operation.stop("callerCancelled") }
      let current = await operation.record
      let verdict = try await pump(
        exec, operation: operation, record: record, space: relay.space, lifetime: lifetime, deadline: deadline, state: state,
        output: ["stdout", "stderr"].reduce(0) { $0 + Int(current.consumed[$1]?.rawValue ?? 0) },
        consumed: current.consumed, stdin: Int(current.accepted["stdin"]?.rawValue ?? 0) + (current.pendingInputs["stdin"]?.payload.count ?? 0),
      )
      try await answer(exec, verdict: verdict, record: record, space: relay.space, lifetime: lifetime)
    } catch {
      // A server going down leaves the operation live in the store; the next boot resumes it.
      if Task.isCancelled || closing { return }
      let message = switch error {
      case let error as TimeoutUnresolved: error.message
      case let error as ExecRefused: error.message
      case let error as OperationError: "\(error.code.rawValue): \(error.message)"
      default: "machine exec failed: \(error)"
      }
      // Once the timeout has asked for a stop, any failure leaves the process's outcome unknown, and the exit says so instead
      // of passing a placeholder status off as the process's. A failure of a claimed operation once the timeout has passed
      // counts too, and its stop is the timeout's. A failure before any operation was claimed keeps its own message.
      let overdue = operation != nil && deadline?.untilStop() == .zero
      release = overdue ? Self.timeoutStop : "callerCancelled"
      if lifetime.ended.withLock({ $0 }) || overdue {
        await answerUnresolved(exec, record: record, space: relay.space, lifetime: lifetime, message: message)
      } else if lifetime.answer() {
        try? await exec.send(.stderr, Array((message + "\n").utf8), waitForCapacity: false)
        // A refusal is the machine's answer; anything else lost the operation's outcome.
        try? await relay.space.finishExec(record.id, error is ExecRefused ? .exited(code: 1) : .machineLost)
        await exec.exit(.exited(code: 1))
      }
    }
    // The caller's endpoint holds whatever it has not acknowledged; the store's copy has no reader left.
    try? await operation?.abandon(release)
  }

  /// The exec's start from its first caller, or nil when none comes within the caller grace.
  private func firstExec(_ endpoint: ChannelEndpoint) async -> IncomingExec? {
    await withTaskGroup(of: IncomingExec?.self) { tasks in
      tasks.addTask {
        var incoming = endpoint.incomingExecs.makeAsyncIterator()
        return await incoming.next()
      }
      tasks.addTask {
        @Dependency(\.continuousClock) var clock
        try? await clock.sleep(for: Self.callerGrace)
        return nil
      }
      defer { tasks.cancelAll() }
      return await tasks.next() ?? nil
    }
  }

  /// Opens the exec's machine operation: argv, cwd, environment, the machine group's secrets, and the session's credential when
  /// the session that minted the exec sent its start.
  private func start(_ exec: IncomingExec, relay: MachineV2ExecRelay, state: ExecRelayState) async throws -> OperationClient.Operation {
    let record = relay.record
    guard try await relay.space.execRecord(record.id)?.terminal == nil else { throw ExecRefused(message: "operationEnded: Exec output is no longer retained") }
    let operations = try await operations(group: record.group)
    let owner = OperationOwner(scope: "exec/" + record.id.rawValue, key: record.id.rawValue)
    var input: [String: JSONValue] = ["argv": .array(exec.start.command.map(JSONValue.string)), "cwd": .string(exec.start.cwd), "stdin": true]
    // The id-token names are the server's alone: set below for the session that owns the exec, never by a caller.
    let idTokenNames: Set<String> = [SessionExecEnvironment.idTokenURL, SessionExecEnvironment.idTokenRequest]
    input["env"] = exec.start.env.map { .object(.init(uniqueKeysWithValues: $0.entries.filter { !idTokenNames.contains($0.key) }.map { ($0.key, .string($0.value)) })) }
    let names = (exec.start.secrets?.entries ?? [:]).filter { !SessionExecEnvironment.reserved.contains($0.key) }
    if !names.isEmpty {
      guard let group = try await relay.space.machine(record.machine)?.group,
            let store = try relay.secrets?.group(group.rawValue) else { throw ExecRefused(message: "invalidInput: Machine group secrets unavailable") }
      var values: [String: JSONValue] = [:]
      for (variable, name) in names.sorted(by: { $0.value < $1.value }) {
        do { values[variable] = .string(try await store.value(of: name)) }
        catch { throw ExecRefused(message: "invalidInput: Secret \(name) unavailable in group \(group.rawValue)") }
      }
      input["secretValues"] = .object(.init(uniqueKeysWithValues: values.map { ($0.key, $0.value) }))
    }
    // Attribution and the session credential follow whoever sent the start, never the record alone: a person who opens a
    // session's exec runs as themselves.
    let sender = relay.starter.sender?.session
    var credentialSession: SessionID?
    if let sender, sender.rawValue == record.caller, let tokens = relay.tokens {
      input["sessionCredential"] = try await credential(tokens: tokens, session: sender, group: record.group, owner: owner, timeout: .seconds(min(exec.start.timeout ?? ExecTokens.longestLife, ExecTokens.longestLife)))
      credentialSession = sender
      @Dependency(\.date) var date
      let minting = tokens.idTokens.environment(spaceURL: tokens.spaceURL, session: sender, machine: record.machine, exec: record.id, timeout: exec.start.timeout, now: date.now)
      // The capability rides in the secret values so the agent masks it.
      var env = input["env"]?.object ?? [:]
      env[SessionExecEnvironment.idTokenURL] = .string(minting.url)
      input["env"] = .object(env)
      var secretValues = input["secretValues"]?.object ?? [:]
      secretValues[SessionExecEnvironment.idTokenRequest] = .string(minting.request)
      input["secretValues"] = .object(secretValues)
    }
    let request = StartRequest(kind: "exec.v1", input: .object(.init(uniqueKeysWithValues: input.map { ($0.key, $0.value) })), caller: await relay.space.startCaller(sender))
    let operation: OperationClient.Operation
    do {
      operation = try await operations.open(owner, machine: record.machine.rawValue, start: request, consumer: state.json())
    } catch {
      if let credentialSession {
        let claimed = ((try? await operations.lookup(owner)) ?? nil) != nil
        relay.tokens?.finishCredentialAttempt(session: credentialSession, group: record.group, scope: owner.scope, key: owner.key, claimed: claimed)
      }
      if let error = error as? OperationError { throw ExecRefused(message: "\(error.code.rawValue): \(error.message)") }
      throw error
    }
    if let credentialSession { relay.tokens?.finishCredentialAttempt(session: credentialSession, group: record.group, scope: owner.scope, key: owner.key, claimed: true) }
    execEndpoints[record.id.rawValue]?.operation = operation
    try await relay.space.recordExecCommand(record.id, command: exec.start.command.joined(separator: " "))
    return operation
  }

  /// Moves the exec until its operation's output is drained, and returns the verdict. Output goes to the caller in arrival order
  /// from `output` (the combined cursor the store resumes at); the store forgets a chunk only once the caller acknowledged all of
  /// it. Stdin is acknowledged to the caller only once durable, from `stdin` on. Output cut at the budget (`state.cut`) ends
  /// there: the caller gets what it has not acknowledged up to the cut, and the store lets the rest go once it has.
  private func pump(
    _ exec: IncomingExec, operation: OperationClient.Operation, record: ExecRecord, space: Space, lifetime: RelayLifetime,
    deadline: ExecDeadline?, state: ExecRelayState, output: Int, consumed: [String: Offset], stdin: Int,
  ) async throws -> Verdict {
    let key = record.id.rawValue
    let ledger = AckLedger(cursor: output)
    let cut = OutputCut()
    let stdinPiece = min(64 * 1024, await operation.record.inputChannels.first { $0.name == "stdin" }?.windowBytes ?? 64 * 1024)
    return try await withThrowingTaskGroup(of: Verdict?.self) { tasks in
      tasks.addTask {
        @Dependency(\.continuousClock) var clock
        while true {
          try await clock.sleep(for: .seconds(1))
          if await self.callerExpired(key) {
            let cut = await exec.stopOutput()
            try await operation.abandon("callerGone", consumer: state.cutting(at: cut).json())
            return nil
          }
        }
      }
      tasks.addTask {
        var through = stdin
        do {
          for try await bytes in exec.stdin {
            var index = 0
            while index < bytes.count {
              let count = min(stdinPiece, bytes.count - index)
              try await operation.write("stdin", ChannelPayload(data: Data(bytes[index ..< index + count])))
              index += count; through += count
              await exec.acknowledgeStdin(through: through)
            }
          }
          try await operation.write("stdin", ChannelPayload(data: Data()), end: true)
        } catch let error as OperationError where error.code == .operationEnded {}
        return nil
      }
      tasks.addTask {
        for await _ in exec.kills { try await operation.stop("callerCancelled"); break }
        return nil
      }
      tasks.addTask {
        for await cursor in exec.acknowledgements {
          for ack in ledger.acknowledged(through: cursor) { try await operation.acknowledge(channel: ack.channel, through: ack.through) }
          ledger.commit(through: cursor)
          if cut.release(acknowledged: ledger.cursor) { try await operation.abandon("outputLimit") }
        }
        return nil
      }
      if let deadline {
        tasks.addTask {
          @Dependency(\.continuousClock) var clock
          try await clock.sleep(for: deadline.untilStop())
          lifetime.ended.withLock { $0 = true }
          // Output keeps flowing until the process is gone, so the caller gets the tail and the real termination, but only
          // until the grace ends: then it is answered with an unknown status, and nothing more reaches it.
          try await operation.stop(Self.timeoutStop)
          try await clock.sleep(for: deadline.untilAnswer())
          let message = "Machine exec did not end within \(Self.timeoutStopGrace.components.seconds) s of its timeout stop"
          await self.answerUnresolved(exec, record: record, space: space, lifetime: lifetime, message: message)
          throw TimeoutUnresolved(message: message)
        }
      }
      tasks.addTask {
        try await self.relayOutput(exec, operation: operation, lifetime: lifetime, ledger: ledger, cut: cut, state: state, output: output, consumed: consumed)
        return try await operation.verdict()
      }
      defer { tasks.cancelAll() }
      while let next = try await tasks.next() {
        if let verdict = next { return verdict }
      }
      throw OperationError(.invalidResponse, operation: operation.id)
    }
  }

  /// Sends the operation's output to the caller in arrival order until it is drained. With a budget within the queue's ceiling,
  /// output is read ahead into an `ExecOutputQueue` while a send waits for the caller's window, so the budget sees an overrun
  /// even when the caller is not reading; otherwise each send holds the reader. Reaching the budget, or the cut a restart
  /// found, sends what fits the window at once and cuts the rest; the operation is stopped with the cursor the caller's output
  /// ends at, and abandoned once the caller holds everything up to it. Returns once every admitted byte is in the caller's
  /// endpoint and the output is drained.
  private func relayOutput(
    _ exec: IncomingExec, operation: OperationClient.Operation, lifetime: RelayLifetime, ledger: AckLedger, cut: OutputCut,
    state: ExecRelayState, output: Int, consumed: [String: Offset],
  ) async throws {
    let limit = min(exec.start.maxOutput ?? Int.max, state.cut ?? Int.max)
    let queue = ExecOutputQueue(exec)
    let scope = TaskScope()
    let sending = try queue.map { queue in try scope.run("exec-output-queue") { _ = try await queue.run() } }
    do {
      defer { sending?.cancel() }
      var used = output
      var after: UInt64?
      var cutting = used >= limit
      if cutting { try await cutOutput(exec, operation: operation, state: state, queue: queue, sending: sending, ledger: ledger, cut: cut) }
      while let chunks = try await operation.output(after: after) {
        for chunk in chunks {
          after = chunk.sequence
          guard !cutting, !lifetime.answered else { continue }
          let retained = chunk.payload.data ?? Data()
          let skipped = min(retained.count, max(0, Int(consumed[chunk.channel]?.rawValue ?? 0) - Int(chunk.from.rawValue)))
          let bytes = retained.dropFirst(skipped)
          let stream: ExecOutputStream = chunk.channel == "stderr" ? .stderr : .stdout
          let admitted = Array(bytes.prefix(max(0, limit - used)))
          // Ledgered before it is sent, so an acknowledgement racing the send still finds it.
          if !admitted.isEmpty {
            ledger.add(channel: chunk.channel, from: Offset(rawValue: chunk.from.rawValue + UInt64(skipped)), count: admitted.count, end: used + admitted.count)
          }
          used += admitted.count
          cutting = admitted.count < bytes.count || used >= limit
          if let queue {
            queue.enqueue(admitted, to: stream)
          } else if !admitted.isEmpty {
            try await exec.send(stream, admitted, waitForCapacity: !cutting)
          }
          if cutting { try await cutOutput(exec, operation: operation, state: state, queue: queue, sending: sending, ledger: ledger, cut: cut) }
        }
      }
      queue?.finish(.stdout)
      queue?.finish(.stderr)
      try await sending?.value
      await scope.close()
    } catch {
      await scope.close()
      throw error
    }
  }

  /// Ends the caller's output where it is now. The stop and that cursor are durable together; what the caller has not
  /// acknowledged up to the cursor stays retained, so a restart still delivers it.
  private func cutOutput(
    _ exec: IncomingExec, operation: OperationClient.Operation, state: ExecRelayState, queue: ExecOutputQueue?,
    sending: Task<Void, any Error>?, ledger: AckLedger, cut: OutputCut,
  ) async throws {
    // The queue sends what fits and stops the output once it has run dry; the cursor is final only then.
    if let queue {
      await queue.overrun()
      try await sending?.value
    }
    // An endpoint that no longer has the exec has nothing left to deliver.
    guard let end = await exec.stopOutput() else { try await operation.abandon("outputLimit"); return }
    try await operation.stop("outputLimit", consumer: state.cutting(at: end).json())
    cut.set(end)
    if cut.release(acknowledged: ledger.cursor) { try await operation.abandon("outputLimit") }
  }

  /// Answers the caller from the verdict, and records the same ending: the record never says the process exited while the
  /// caller was told its status is unknown.
  private func answer(_ exec: IncomingExec, verdict: Verdict, record: ExecRecord, space: Space, lifetime: RelayLifetime) async throws {
    if verdict.tag == .failed {
      let error = verdict.error ?? OperationError(.invalidResponse)
      throw ExecRefused(message: "\(error.code.rawValue): \(error.message)")
    }
    let reason = verdict.tag == .stopped ? verdict.reason : nil
    let termination = verdict.result?.object?["termination"]?.object
    let status: ExitStatus
    let ending: ExecTerminalState
    if termination?["tag"]?.stringValue == "signal", let signal = termination?["signal"]?.intValue {
      status = .signaled(signal: signal); ending = .signaled(signal: signal)
    } else if termination?["tag"]?.stringValue == "exit", let code = termination?["code"]?.intValue {
      status = .exited(code: code); ending = .exited(code: code)
    } else if reason == Self.timeoutStop {
      throw TimeoutUnresolved(message: "Machine exec stopped at its timeout; the process's own status was not reported")
    } else if let reason {
      // Stopped before the process reported a status: exit 1, the record says why.
      guard lifetime.answer() else { return }
      try? await exec.send(.stderr, Array("requestCancelled: Machine exec stopped: \(reason)\n".utf8), waitForCapacity: false)
      try? await space.finishExec(record.id, Self.cancelling(reason) ? .cancelled : .exited(code: 1))
      await exec.exit(.exited(code: 1))
      return
    } else {
      throw OperationError(.invalidResponse, message: "Machine exec ended without the process's status")
    }
    guard lifetime.answer() else { return }
    // A stop the caller's side asked for ends the record as cancelled; the caller still gets the process's real status.
    let cancelled = Self.cancelling(reason)
    try? await space.finishExec(record.id, cancelled ? .cancelled : ending)
    await exec.exit(status, timedOut: reason == Self.timeoutStop ? .killed : nil)
  }

  private static func cancelling(_ reason: String?) -> Bool { reason == "callerCancelled" || reason == "callerGone" }

  private func answerUnresolved(_ exec: IncomingExec, record: ExecRecord, space: Space, lifetime: RelayLifetime, message: String) async {
    guard lifetime.answer() else { return }
    try? await exec.send(.stderr, Array("requestDeadline: \(message)\n".utf8), waitForCapacity: false)
    // Output still queued or in flight must not reach the caller after this answer.
    await exec.stopOutput()
    try? await space.finishExec(record.id, .machineLost)
    await exec.exit(.exited(code: 1), timedOut: .statusUnknown)
  }
}

/// A timeout stop that never brought the process's own status back.
private struct TimeoutUnresolved: Error {
  let message: String
}

/// The machine or the server refused the exec: its caller gets the reason and exit 1.
private struct ExecRefused: Error {
  let message: String
}

/// Maps the caller's combined cursor to per-channel consumption, including a prefix of a machine chunk. The cursor moves
/// only after its channel acknowledgements are durable, so a cut cannot discard bytes before their consumption is saved.
final class AckLedger: Sendable {
  struct Acknowledgement {
    let channel: String
    let through: Offset
  }

  private struct Pending {
    let end: Int
    let channel: String
    var from: Offset
    var count: Int
  }

  private let state: Mutex<(pending: [Pending], acknowledged: Int)>

  init(cursor: Int) { state = Mutex(([], cursor)) }

  var cursor: Int { state.withLock { $0.acknowledged } }

  func add(channel: String, from: Offset, count: Int, end: Int) {
    state.withLock { $0.pending.append(Pending(end: end, channel: channel, from: from, count: count)) }
  }

  func commit(through cursor: Int) { state.withLock { $0.acknowledged = max($0.acknowledged, cursor) } }

  func acknowledged(through cursor: Int) -> [Acknowledgement] {
    state.withLock { state in
      var newest: [String: Offset] = [:]
      while let first = state.pending.first {
        let count = min(first.count, cursor - (first.end - first.count))
        guard count > 0 else { break }
        let through = Offset(rawValue: first.from.rawValue + UInt64(count))
        newest[first.channel] = through
        if count == first.count {
          state.pending.removeFirst()
        } else {
          state.pending[0].from = through
          state.pending[0].count -= count
          break
        }
      }
      return newest.keys.sorted().map { Acknowledgement(channel: $0, through: newest[$0]!) }
    }
  }
}

/// Where the caller's output ends once it was cut, and whether the store's copy was let go: once, when the caller has
/// acknowledged everything up to there.
final class OutputCut: Sendable {
  private let state = Mutex<(end: Int?, released: Bool)>((nil, false))

  func set(_ end: Int) { state.withLock { $0.end = $0.end ?? end } }

  func release(acknowledged: Int) -> Bool {
    state.withLock { state in
      guard let end = state.end, !state.released, acknowledged >= end else { return false }
      state.released = true
      return true
    }
  }
}

/// A timed exec's two moments: when its timeout stops it (`stopAt`, fixed when the exec is admitted and kept across restarts),
/// and the latest its caller is answered, `timeoutStopGrace` later, whether or not the stop has ended the process.
struct ExecDeadline: Sendable {
  let untilStop: @Sendable () -> Duration
  let untilAnswer: @Sendable () -> Duration

  init(stopAt: Date, now: Date, clock: some Clock<Duration>) {
    // Both from the stored instant, so a restart past either moment reaches it at once and never renews the grace.
    let left = Duration.seconds(stopAt.timeIntervalSince(now))
    let stop = clock.now.advanced(by: max(.zero, left))
    let answer = clock.now.advanced(by: max(.zero, left + MachineV2Service.timeoutStopGrace))
    untilStop = { max(.zero, clock.now.duration(to: stop)) }
    untilAnswer = { max(.zero, clock.now.duration(to: answer)) }
  }
}

final class RelayLifetime: Sendable {
  /// Set once the timeout has asked the supervisor to stop the exec.
  let ended = Mutex(false)
  private let claimed = Mutex(false)

  /// Whether the caller's one exit has been claimed.
  var answered: Bool { claimed.withLock { $0 } }

  /// Claims the one exit the caller gets; false once it was sent.
  func answer() -> Bool {
    claimed.withLock { answered in
      defer { answered = true }
      return !answered
    }
  }
}

extension Space {
  /// `StartRequest.caller` for a start `session` caused: its id, title and group, read at start time.
  /// Display-only attribution, so a session that can't be read (gone, or no session at all) leaves it out rather than failing the start.
  func startCaller(_ session: SessionID?) async -> StartRequest.Caller? {
    guard let session, let record = try? await sessions.record(session) else { return nil }
    return .init(session: session.rawValue, title: record.title, group: record.group.rawValue)
  }
}

/// Who is on an exec's caller socket: a session, a person (any persona of one account), or the --dev seat.
public enum ExecLeg: Hashable, Sendable {
  case session(SessionID)
  case person(AccountID)
  case anonymous

  public init(_ actor: SpaceCore.Actor) {
    switch actor {
    case let .session(id): self = .session(id)
    case let .person(_, account): self = .person(account)
    case .anonymous: self = .anonymous
    }
  }

  var session: SessionID? { if case let .session(id) = self { id } else { nil } }
}

/// The first leg to send an exec's start owns it; a resumed exec's owner is the holder its operation kept. Only the owner's legs
/// are ever attached (`MachineV2Service.admits`), so a start from any other actor is a leg that slipped in before the owner was
/// known: it ends that leg's connection instead of reaching the endpoint.
final class ExecStarter: Sendable {
  private let owner: Mutex<ExecLeg?>
  var sender: ExecLeg? { owner.withLock { $0 } }

  init(owner: ExecLeg? = nil) {
    self.owner = Mutex(owner)
  }

  func admits(_ bytes: [UInt8], from leg: ExecLeg) -> Bool {
    owner.withLock { owner in
      if let owner { return owner == leg }
      guard let frame = try? FrameCodec.decode(bytes), frame.opcode == .execStart else { return true }
      owner = leg; return true
    }
  }
}

private struct GatedLeg: FrameTransport {
  let inbound: AsyncStream<[UInt8]>
  let base: WebSocketTransport
  func send(_ frame: [UInt8]) async throws { try await base.send(frame) }
  func close() { base.close() }
}
