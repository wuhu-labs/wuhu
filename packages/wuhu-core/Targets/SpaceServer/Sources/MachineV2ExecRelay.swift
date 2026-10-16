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
import class OperationClient.OperationClient
import struct OperationClient.OperationOwner
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteReceipt
import Serve
import struct SessionDomain.SessionID
import SpaceCore
import Synchronization

struct MachineV2ExecRelay: Sendable {
  let record: ExecRecord
  let endpoint: ChannelEndpoint
  let starter: ExecStarter
  let space: Space
  let tokens: ExecTokens?
  let secrets: SpaceSecretStores?
}

extension MachineV2Service {
  static let timeoutStop = "timeout"
  // Seconds, the way the v1 agent bounds a caller's timeout: a larger Duration traps.
  static let timeoutCeiling = 1e9
  /// How long a timeout stop may take to answer, end the process and drain its output: the supervisor's five-second
  /// SIGKILL escalation plus margin. Past it the exec fails as a deadline instead of holding its caller. Task-local
  /// so tests can shorten it.
  @TaskLocal static var timeoutStopGrace: Duration = .seconds(30)

  func noteMinted(_ record: ExecRecord, space: Space) {
    relays.continuation.yield(.minted(record, space))
  }

  func expireUnconnected(_ record: ExecRecord, space: Space) async {
    @Dependency(\.continuousClock) var clock
    do { try await clock.sleep(for: .seconds(60)) } catch { return }
    if execEndpoints[record.id.rawValue] == nil { try? await space.finishExec(record.id, .reaped) }
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
    for (key, entry) in execEndpoints where entry.completed.map({ date.now.timeIntervalSince($0) >= 600 }) == true {
      execEndpoints[key] = nil
      killedExecs.remove(key)
    }
    // The route refuses another actor with 409 before upgrading; this covers the race between that check and here.
    guard admits(record, leg: leg) else { socket.close(); return }
    let caller = UUID()
    if execEndpoints[key] == nil {
      guard execEndpoints.count < 4096 else { socket.close(); return }
      let entry = ExecEndpoint(endpoint: ChannelEndpoint())
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
    return date.now.timeIntervalSince(disconnected) >= 60
  }

  func killExec(_ record: ExecRecord) async throws {
    killedExecs.insert(record.id.rawValue)
    if let stops = execOperations[record.id.rawValue] {
      let operations = try await client(group: record.group)
      try await stopOperation(operations, id: stops.id, reason: "callerCancelled", within: stops.budget)
    }
  }

  func serveExec(_ relay: MachineV2ExecRelay) async {
    let record = relay.record
    defer {
      @Dependency(\.date) var date
      execEndpoints[record.id.rawValue]?.completed = date.now
      execOperations[record.id.rawValue] = nil
      killedExecs.remove(record.id.rawValue)
    }
    let exec = await withTaskGroup(of: IncomingExec?.self) { tasks in
      tasks.addTask {
        var incoming = relay.endpoint.incomingExecs.makeAsyncIterator()
        return await incoming.next()
      }
      tasks.addTask {
        @Dependency(\.continuousClock) var clock
        try? await clock.sleep(for: .seconds(60))
        return nil
      }
      defer { tasks.cancelAll() }
      return await tasks.next() ?? nil
    }
    guard let exec else { try? await relay.space.finishExec(record.id, .reaped); return }
    let lifetime = RelayLifetime()
    // A timed exec's one deadline, fixed at admission: every exchange and stop that holds up its caller's answer, whichever path
    // sends it, ends by the time the caller must be answered. A stop sent after the answer gets a fresh retry window instead.
    @Dependency(\.continuousClock) var clock
    let deadline = exec.start.timeout.map { ExecDeadline(timeout: $0, clock: clock) }
    let limit = deadline.map(RetryBudget.init(answering:))
    do {
      guard try await relay.space.execRecord(record.id)?.terminal == nil else { throw OperationError(.operationEnded, message: "Exec output is no longer retained") }
      let client = try await client(group: record.group)
      _ = try await retryingExchange(within: limit) { try await client.describe(record.machine.rawValue, exchangeLimit: $0) }
      let owner = OperationOwner(scope: "exec/" + record.id.rawValue, key: record.id.rawValue)
      var input: [String: JSONValue] = ["argv": .array(exec.start.command.map(JSONValue.string)), "cwd": .string(exec.start.cwd), "stdin": true]
      input["env"] = exec.start.env.map { .object(.init(uniqueKeysWithValues: $0.entries.map { ($0.key, .string($0.value)) })) }
      let names = (exec.start.secrets?.entries ?? [:]).filter { !SessionExecEnvironment.reserved.contains($0.key) }
      if !names.isEmpty {
        guard let group = try await relay.space.machine(record.machine)?.group,
              let store = try relay.secrets?.group(group.rawValue) else { throw OperationError(.invalidInput, message: "Machine group secrets unavailable") }
        var values: [String: JSONValue] = [:]
        for (variable, name) in names.sorted(by: { $0.value < $1.value }) {
          do { values[variable] = .string(try await store.value(of: name)) }
          catch { throw OperationError(.invalidInput, message: "Secret \(name) unavailable in group \(group.rawValue)") }
        }
        input["secretValues"] = .object(.init(uniqueKeysWithValues: values.map { ($0.key, $0.value) }))
      }
      let claimed = Mutex<UUID?>(nil)
      var reserved = false
      // Attribution and the session credential follow whoever sent the start, never the record alone: a person
      // who opens a session's exec runs as themselves.
      let sender = relay.starter.sender?.session
      let owned = sender != nil && sender?.rawValue == record.caller
      if owned, let caller = record.caller, let tokens = relay.tokens {
        input["sessionCredential"] = try await credential(tokens: tokens, session: SessionID(rawValue: caller), group: record.group, owner: owner, timeout: .seconds(min(exec.start.timeout ?? ExecTokens.longestLife, ExecTokens.longestLife)))
        reserved = true
      }
      let id: UUID
      do {
        id = try await client.start(record.machine.rawValue, request: .init(kind: "exec.v1", input: .object(.init(uniqueKeysWithValues: input.map { ($0.key, $0.value) })), caller: relay.space.startCaller(sender)), owner: owner, onClaim: { id in claimed.withLock { $0 = id } })
      } catch {
        // The claimed operation is stopped after the caller is answered, like any stop after a relay failure.
        if let id = claimed.withLock({ $0 }) { execOperations[record.id.rawValue] = ExecStops(id: id, limit: limit, lifetime: lifetime) }
        if reserved, let caller = record.caller { relay.tokens?.finishCredentialAttempt(session: SessionID(rawValue: caller), group: record.group, scope: owner.scope, key: owner.key, claimed: claimed.withLock { $0 != nil }) }
        throw error
      }
      if reserved, let caller = record.caller { relay.tokens?.finishCredentialAttempt(session: SessionID(rawValue: caller), group: record.group, scope: owner.scope, key: owner.key, claimed: true) }
      execOperations[record.id.rawValue] = ExecStops(id: id, limit: limit, lifetime: lifetime)
      try await relay.space.recordExecCommand(record.id, command: exec.start.command.joined(separator: " "))
      if killedExecs.contains(record.id.rawValue) { try await stopOperation(client, id: id, reason: "callerCancelled", within: limit) }
      let verdict = try await pump(exec, client: client, id: id, key: record.id.rawValue, lifetime: lifetime, deadline: deadline, limit: limit) { message in
        await self.answerUnresolved(exec, record: record, space: relay.space, lifetime: lifetime, message: message)
      }
      if let error = verdict.error { throw error }
      let termination = verdict.result?.object?["termination"]?.object
      let timedOut = verdict.tag == .stopped && verdict.reason == Self.timeoutStop
      if timedOut, termination == nil {
        throw TimeoutUnresolved(message: "Machine exec stopped at its timeout; the process's own status was not reported")
      }
      if verdict.tag == .stopped, !timedOut {
        throw OperationError(.requestCancelled, message: "Machine exec stopped: \(verdict.reason ?? "stopped")", operation: id)
      }
      guard let termination else { throw OperationError(.invalidResponse, operation: id) }
      let status: ExitStatus
      let ending: ExecTerminalState
      if termination["tag"]?.stringValue == "signal", let signal = termination["signal"]?.intValue {
        status = .signaled(signal: signal); ending = .signaled(signal: signal)
      } else if termination["tag"]?.stringValue == "exit", let code = termination["code"]?.intValue {
        status = .exited(code: code); ending = .exited(code: code)
      } else { throw OperationError(.invalidResponse, operation: id) }
      // Whoever answers the caller records the ending, so the record never says the process exited while the
      // caller was told its status is unknown.
      guard lifetime.answer() else { return }
      try? await relay.space.finishExec(record.id, ending)
      await exec.exit(status, timedOut: timedOut ? .killed : nil)
    } catch is CancellationError {
      await stopRelay(record)
      try? await relay.space.finishExec(record.id, .machineLost)
    } catch {
      let message: String
      if let error = error as? TimeoutUnresolved { message = error.message }
      else if let error = error as? OperationError { message = "\(error.code.rawValue): \(error.message)" }
      else { message = "machine exec failed: \(error)" }
      // Once the timeout has asked for a stop, any failure leaves the process's outcome unknown, like a lost
      // machine's, and the exit says so instead of passing its placeholder status off as the process's. The
      // stop that cleans up comes after the exit, so it never holds the caller.
      if lifetime.ended.withLock({ $0 }) {
        await answerUnresolved(exec, record: record, space: relay.space, lifetime: lifetime, message: message)
      } else if lifetime.answer() {
        try? await exec.send(.stderr, Array((message + "\n").utf8), waitForCapacity: false)
        try? await relay.space.finishExec(record.id, .exited(code: 1))
        await exec.exit(.exited(code: 1))
      }
      await stopRelay(record)
    }
  }

  private func answerUnresolved(_ exec: IncomingExec, record: ExecRecord, space: Space, lifetime: RelayLifetime, message: String) async {
    guard lifetime.answer() else { return }
    try? await exec.send(.stderr, Array("requestDeadline: \(message)\n".utf8), waitForCapacity: false)
    try? await space.finishExec(record.id, .machineLost)
    await exec.exit(.exited(code: 1), timedOut: .statusUnknown)
  }

  private func stopRelay(_ record: ExecRecord) async {
    guard let stops = execOperations[record.id.rawValue], let client = try? await client(group: record.group) else { return }
    try? await stopOperation(client, id: stops.id, reason: "callerCancelled", within: stops.budget)
  }

  /// Stops one machine operation, retrying transient failures. `id` is the operation this exec started, captured by the caller and
  /// never looked up again, so a retry can only reach that operation. A stop is idempotent on the machine (the first reason wins), so
  /// a retry after an applied stop whose response was lost is harmless. A stop makes one attempt even when its budget is already
  /// spent, so the client persists its intent and the relay's later stop, or a reconcile, still sends it.
  private func stopOperation(_ client: OperationClient, id: UUID, reason: String, within limit: RetryBudget?) async throws {
    _ = try await retryingExchange(within: limit, firstAttempt: MachineV2ExecRetry.lastStopAttempt) { try await client.stop(id, reason: reason, exchangeLimit: $0) }
  }

  private func pump(
    _ exec: IncomingExec, client: OperationClient, id: UUID, key: String, lifetime: RelayLifetime, deadline: ExecDeadline?, limit: RetryBudget?,
    unresolved: @escaping @Sendable (String) async -> Void,
  ) async throws -> Verdict {
    let budget = RelayOutputBudget()
    return try await withThrowingTaskGroup(of: Verdict?.self) { tasks in
      tasks.addTask {
        @Dependency(\.continuousClock) var clock
        var ticks = 0
        while true {
          try await clock.sleep(for: .seconds(1))
          if await self.callerExpired(key) {
            await exec.stopOutput()
            try await self.stopOperation(client, id: id, reason: "callerGone", within: limit)
            return nil
          }
          ticks += 1
          if ticks >= MachineV2ExecRetry.reconcileTicks { _ = try await retryingExchange(within: limit) { try await client.reconcile(id, exchangeLimit: $0) }; ticks = 0 }
        }
      }
      tasks.addTask {
        for try await bytes in exec.stdin { try await self.input(client, id: id, bytes: Data(bytes), end: false, within: limit) }
        try await self.input(client, id: id, bytes: Data(), end: true, within: limit)
        return nil
      }
      tasks.addTask {
        for await _ in exec.kills { await exec.stopOutput(); try await self.stopOperation(client, id: id, reason: "callerCancelled", within: limit); break }
        return nil
      }
      if let deadline {
        tasks.addTask {
          @Dependency(\.continuousClock) var clock
          try await clock.sleep(for: deadline.untilStop())
          lifetime.ended.withLock { $0 = true }
          // Output keeps flowing until the process group is gone, so the
          // result carries the tail and the real termination, but only until
          // the deadline. A stop that fails, never answers or never ends the
          // process answers the caller at once, before any teardown that
          // could hold it.
          try await withThrowingTaskGroup(of: Void.self) { bound in
            bound.addTask {
              do { try await self.stopOperation(client, id: id, reason: Self.timeoutStop, within: limit) }
              catch is CancellationError { throw CancellationError() }
              catch {
                let message = "Machine exec timeout stop failed: \(error)"
                await unresolved(message)
                throw TimeoutUnresolved(message: message)
              }
            }
            bound.addTask {
              @Dependency(\.continuousClock) var clock
              try await clock.sleep(for: deadline.untilAnswer())
              let message = "Machine exec did not end within \(Self.timeoutStopGrace.components.seconds) s of its timeout stop"
              await unresolved(message)
              throw TimeoutUnresolved(message: message)
            }
            while try await bound.next() != nil {}
          }
          return nil
        }
      }
      for (channel, stream) in [("stdout", ExecOutputStream.stdout), ("stderr", .stderr)] {
        tasks.addTask {
          while true {
            let snapshot: OperationSnapshot
            do { snapshot = try await retryingExchange(within: limit) { try await client.poll(id, channel: channel, holdMs: 20000, exchangeLimit: $0) } }
            catch let error as OperationError where error.code == .operationEnded && lifetime.ended.withLock({ $0 }) {
              // The client refuses to poll a stopped operation until its
              // verdict is known; stop answers with it once the process is
              // gone, and the rest of the output drains after that.
              try await self.awaitVerdict(client, id: id, within: limit)
              continue
            }
            for payload in try await client.takeOutput(id, channel: channel) {
              let bytes = payload.data ?? Data()
              let admitted = budget.bytes.withLock { used in
                let count = min(bytes.count, max(0, (exec.start.maxOutput ?? Int.max) - used)); used += count; return count
              }
              if admitted > 0 { try await exec.send(stream, Array(bytes.prefix(admitted))) }
              if admitted < bytes.count || budget.bytes.withLock({ $0 >= (exec.start.maxOutput ?? Int.max) }) {
                await exec.stopOutput()
                try await self.stopOperation(client, id: id, reason: "outputLimit", within: limit)
              }
            }
            if snapshot.channelEnd, let verdict = snapshot.verdict {
              _ = try await retryingExchange(within: limit) { try await client.poll(id, channel: channel, terminalAck: true, exchangeLimit: $0) }
              return verdict
            }
            if snapshot.channelEnd {
              @Dependency(\.continuousClock) var clock
              try await clock.sleep(for: .milliseconds(100))
            }
          }
        }
      }
      defer { tasks.cancelAll() }
      var outputs = 0; var terminal: Verdict?
      while let verdict = try await tasks.next() {
        if let verdict { outputs += 1; terminal = verdict }
        if outputs == 2, let terminal { return terminal }
      }
      throw OperationError(.invalidResponse, operation: id)
    }
  }

  private func awaitVerdict(_ client: OperationClient, id: UUID, within limit: RetryBudget?) async throws {
    @Dependency(\.continuousClock) var clock
    while try await retryingExchange(within: limit, { try await client.reconcile(id, exchangeLimit: $0) }).verdict == nil {
      try await clock.sleep(for: .milliseconds(100))
    }
  }

  /// Writes one stdin chunk until the machine accepts all of it. The client persists the chunk at its stream offset until a receipt
  /// covers it and resends exactly that chunk, and the machine accepts an offset it already holds only with identical bytes, so a
  /// retried write whose earlier attempt was applied (response lost) neither duplicates nor reorders stdin.
  private func input(_ client: OperationClient, id: UUID, bytes: Data, end: Bool, within limit: RetryBudget?) async throws {
    @Dependency(\.continuousClock) var clock
    while true {
      let receipt: WriteReceipt
      do { receipt = try await retryingExchange(within: limit) { try await client.write(id, channel: "stdin", payload: ChannelPayload(data: bytes), end: end, exchangeLimit: $0) } }
      catch let error as OperationError where error.code == .operationEnded { return }
      if !receipt.blocked { return }
      try await clock.sleep(for: .milliseconds(10))
    }
  }
}

/// A timeout stop that never brought the process's own status back.
private struct TimeoutUnresolved: Error {
  let message: String
}

/// A timed exec's two moments, fixed once when the exec is admitted: when its timeout stops it, and the latest its
/// caller is answered, `timeoutStopGrace` later, whether or not the stop has ended the process.
struct ExecDeadline: Sendable {
  let untilStop: @Sendable () -> Duration
  let untilAnswer: @Sendable () -> Duration

  init(timeout: Double, clock: some Clock<Duration>) {
    let stop = clock.now.advanced(by: .seconds(min(timeout, MachineV2Service.timeoutCeiling)))
    let answer = stop.advanced(by: MachineV2Service.timeoutStopGrace)
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

/// Runs one idempotent operation exchange (describe, poll, terminal acknowledgement, reconcile, stdin write, stop), retrying it while
/// it fails with a transient exchange error: a request deadline or a transport failure says nothing about the remote process, so a
/// slow or dropped exchange must not end a healthy exec. The budget is hard: it is `MachineV2ExecRetry.window` from the first
/// attempt, cut to `limit` when one is given, and each attempt gets the remaining budget as its exchange limit, so the call returns
/// within the budget however long a single exchange would otherwise hold. Retries back off from 100 ms to 1 s; when the budget runs
/// out the last transient error is rethrown as the cause. Every other error, including the client's own lease-silence and
/// caller-deadline verdicts, is returned at once, and cancellation ends the retries. `firstAttempt` is the least exchange limit the
/// first attempt gets, so a positive one makes the exchange run at least once however little budget is left.
func retryingExchange<T>(within limit: RetryBudget? = nil, firstAttempt: Duration = .zero, _ exchange: (Duration) async throws -> T) async throws -> T {
  @Dependency(\.continuousClock) var clock
  let window = RetryBudget(MachineV2ExecRetry.window)
  func remaining() -> Duration { min(window.remaining(), limit?.remaining() ?? window.remaining()) }
  var delay = Duration.milliseconds(100)
  var last: OperationError?
  var floor = firstAttempt
  while true {
    let budget = max(remaining(), floor)
    floor = .zero
    guard budget > .zero else { throw last ?? OperationError(.requestDeadline, message: "Exec exchange budget exhausted") }
    do { return try await exchange(budget) }
    catch let error as OperationError where error.code == .requestDeadline || error.code == .transport {
      last = error
      guard remaining() > delay else { throw error }
      try await clock.sleep(for: delay)
      delay = min(delay * 2, .seconds(1))
    }
  }
}

/// What bounds a later stop of one relayed exec's machine operation: the exec's answer deadline while the stop would hold up the
/// caller's answer, a fresh retry window once the caller has been answered.
struct ExecStops: Sendable {
  let id: UUID
  let limit: RetryBudget?
  let lifetime: RelayLifetime

  var budget: RetryBudget? { lifetime.answered ? nil : limit }
}

/// A deadline on the dependency clock, shared by every retried exchange it bounds.
struct RetryBudget: Sendable {
  let remaining: @Sendable () -> Duration

  /// A timed exec's budget: until its caller must be answered, the timeout's stop grace after the timeout.
  init(answering deadline: ExecDeadline) { remaining = deadline.untilAnswer }

  init(_ total: Duration) {
    @Dependency(\.continuousClock) var clock
    remaining = Self.deadline(clock: clock, after: total)
  }

  private static func deadline<C: Clock<Duration>>(clock: C, after total: Duration) -> @Sendable () -> Duration {
    let end = clock.now.advanced(by: total)
    return { clock.now.duration(to: end) }
  }
}

enum MachineV2ExecRetry {
  /// How long one retried exchange keeps trying through transient failures. Shorter than the default operation lease, so the relay
  /// reports the transient cause itself before the client would declare the operation silent.
  static let window: Duration = .seconds(30)
  /// The exchange limit of a stop's one attempt once its budget is spent.
  static let lastStopAttempt: Duration = .seconds(1)
  /// Seconds between the relay's liveness reconciles of a running exec.
  @TaskLocal static var reconcileTicks = 20
}

private final class RelayOutputBudget: Sendable {
  let bytes = Mutex(0)
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

/// The first leg to send an exec's start owns it. Only the owner's legs are ever attached (`MachineV2Service.admits`), so a start
/// from any other actor is a leg that slipped in before the owner was known: it ends that leg's connection instead of reaching the endpoint.
final class ExecStarter: Sendable {
  private let owner = Mutex<ExecLeg?>(nil)
  var sender: ExecLeg? { owner.withLock { $0 } }

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
