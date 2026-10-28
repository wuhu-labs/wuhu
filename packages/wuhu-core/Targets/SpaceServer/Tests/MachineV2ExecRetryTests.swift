import Clocks
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ClockTesting
import Crypto
import Dependencies
import Fetch
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import OperationClient
import OperationProtocol
import OperationRuntime
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

/// One exchange of the v2 exec relay that meets a transient failure.
enum ExecRetrySite: String, CaseIterable, Sendable {
  case describe, reconcile
  /// An external kill (`MachineHub.kill`) of a running exec.
  case kill
  /// A start the machine refused: nothing runs, so nothing is stopped.
  case refused
  /// The stop for a kill that landed while the start was in flight.
  case race
  /// The stop after the relay itself failed the exec.
  case relay
  /// The caller's kill frame.
  case cancel
  case timeout, outputLimit, callerGone

  var stopReason: String? {
    switch self {
    case .describe, .reconcile, .refused: nil
    case .kill, .race, .relay, .cancel: "callerCancelled"
    case .timeout, .outputLimit, .callerGone: rawValue
    }
  }
}

struct ExecRetryCase: Sendable, CustomTestStringConvertible {
  let site: ExecRetrySite
  /// A `requestDeadline` answer instead of a transport failure.
  let deadline: Bool
  /// The machine applies the request before its response is lost.
  let applied: Bool

  var testDescription: String { "\(site.rawValue), \(deadline ? "requestDeadline" : "transport"), \(applied ? "applied" : "not applied")" }

  static let all: [ExecRetryCase] = ExecRetrySite.allCases.flatMap { site in
    [false, true].flatMap { deadline in
      (site.stopReason == nil ? [false] : [false, true]).map { ExecRetryCase(site: site, deadline: deadline, applied: $0) }
    }
  }
}

private struct LostExchange: Error {}

/// What the machine saw: the reason its operation was stopped with, if it was. A stopped operation holds its verdict until
/// `release`, so a retry cannot be pre-empted by the exec ending after an applied stop.
private final class MachineSide: Sendable {
  let stopped = Mutex<String?>(nil)
  /// Opens once `stopped` is set.
  let stop = Gate()
  let released = Gate()
  func release() { released.open() }
}

private struct HeldEcho: OperationKind {
  let side: MachineSide
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    do {
      while let payload = try await channels.read("stdin", upTo: 65536) { try await channels.send(payload, to: "stdout") }
      try await channels.send(.init(data: Data("stderr".utf8)), to: "stderr")
    } catch {
      let reason = await cancellation.reason()
      side.stopped.withLock { $0 = reason ?? "unknown" }
      side.stop.open()
      await side.released.wait()
      throw error
    }
    return ["termination": ["tag": "exit", "code": 7]]
  }
}

/// The injected failure and what followed it.
private struct Fault {
  var armed = false
  var fired = false
  var retried = false
  /// The exec's terminal state when the retry reached the machine ("live" while none).
  var terminalAtRetry: String?
  /// Stop requests sent to the machine.
  var stops = 0
}

/// What the machine has been asked so far.
private struct Seen {
  /// The service's own presence probe has been answered.
  let probed = Gate()
  /// The relay's stdout poll after the first five bytes is held on the machine.
  let heldPoll = Gate()
  /// The lost exchange was retried.
  let retried = Gate()
}

private func refusal(_ code: OperationError.Code, for request: Request) throws -> Response {
  var response = try Response.json(ErrorEnvelope(OperationError(code)), status: .gatewayTimeout)
  response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
  response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
  response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
  return response
}

/// The relay's wall clock. Once the caller is gone, every reading is two minutes past the one before, so the relay counts the
/// caller's disconnect, whenever it records it, as long ago at its next look.
private final class Wall: Sendable {
  let state = Mutex<(gone: Bool, offset: TimeInterval)>((false, 0))
  func now() -> Date {
    Date().addingTimeInterval(state.withLock { state in
      if state.gone { state.offset += 120 }
      return state.offset
    })
  }
}

/// The stops the machine never got, counted once the caller has been answered.
private final class LostStops: Sendable {
  private let state = Mutex<(answered: Bool, lost: Int)>((false, 0))
  /// Opens on the second stop lost after the answer.
  let twiceAfterTheAnswer = Gate()
  func answered() { state.withLock { $0.answered = true } }
  func lost() {
    let count = state.withLock { state -> Int in
      if state.answered { state.lost += 1 }
      return state.lost
    }
    if count >= 2 { twiceAfterTheAnswer.open() }
  }
}

private final class Collected: Sendable {
  struct Value { var stdout = Data(); var stderr = Data(); var status: MachineContract.ExitStatus? }
  let value = Mutex(Value())
  var stdout: String { value.withLock { String(decoding: $0.stdout, as: UTF8.self) } }
  var stderr: String { value.withLock { String(decoding: $0.stderr, as: UTF8.self) } }
  var status: MachineContract.ExitStatus? { value.withLock { $0.status } }
}

@Suite(.deterministicDependencies(clock: ContinuousClock()), .timeLimit(.minutes(3))) struct MachineV2ExecRetryTests {
  /// Each case loses one exchange, as a transport failure or a request deadline, before or after the machine applied it. The relay
  /// must retry that exchange (and only it) while the exec is live, and the exec must end the way it would have without the loss.
  @Test(arguments: ExecRetryCase.all)
  func transientExchangeFailureIsRetriedNotFatal(_ c: ExecRetryCase) async throws {
    let wall = Wall()
    try await withDependencies { $0.date = DateGenerator { wall.now() } } operation: {
      try await run(c, wall: wall)
    }
  }

  private func run(_ c: ExecRetryCase, wall: Wall) async throws {
    let side = MachineSide()
    let fault = Mutex(Fault())
    let seen = Seen()
    let execID = Mutex<ExecID?>(nil)
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "retry_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(HeldEcho(side: side))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let relayFailed = Mutex(false)
    @Sendable func targeted(_ request: Request) -> Bool {
      let operation = request.url.path.contains("/operations/")
      switch c.site {
      case .refused: return false
      case .describe: return request.method == .get && !operation && request.url.path.hasSuffix(record.id.rawValue)
      case .reconcile: return request.method == .get && operation && request.url.query?.contains("channel=") != true
      default: return request.method == .put && request.url.path.hasSuffix("/stop")
      }
    }
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { request in
      if request.method == .get, request.url.query?.contains("channel=stdout&after=5") == true { seen.heldPoll.open() }
      let isStart = request.method == .post && request.url.path.contains("/operations/")
      if c.site == .race, isStart, let id = execID.withLock({ $0 }) { try await hub.kill(id) }
      if request.method == .put, request.url.path.hasSuffix("/stop") { fault.withLock { $0.stops += 1 } }
      if c.site == .refused, isStart {
        fault.withLock { $0.fired = true }
        return try refusal(.capacityExceeded, for: request)
      }
      if c.site == .relay, request.method == .get, request.url.query?.contains("channel=stdout") == true,
         relayFailed.withLock({ value in defer { value = true }; return !value })
      {
        _ = try await agent.handler(request)
        return try refusal(.invalidInput, for: request)
      }
      guard targeted(request) else {
        let response = try await agent.handler(request)
        if request.method == .get, request.url.path.hasSuffix(record.id.rawValue) { seen.probed.open() }
        return response
      }
      let step = fault.withLock { value -> Int in
        guard value.armed else { return 0 }
        if !value.fired { value.fired = true; return 1 }
        return value.retried ? 0 : 2
      }
      if step == 1 {
        if c.applied { _ = try await agent.handler(request) }
        if c.deadline { return try refusal(.requestDeadline, for: request) }
        throw LostExchange()
      }
      if step == 2 {
        let terminal = try await execID.withLock({ $0 }).asyncMap { try await space.execRecord($0)?.terminal.map { "\($0)" } ?? "live" }
        fault.withLock { $0.retried = true; $0.terminalAtRetry = terminal }
        seen.retried.open()
      }
      let response = try await agent.handler(request)
      if step == 0, c.site == .describe { seen.probed.open() }
      return response
    } })
    await hub.configureV2(service)
    let minted = try await space.mintExec(machine: record.id, group: .shared)
    execID.withLock { $0 = minted.id }
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(
      id: minted.id, cwd: "/tmp", command: ["echo-test"],
      maxOutput: c.site == .outputLimit ? 3 : nil, timeout: c.site == .timeout ? 1 : nil,
    ))
    let collected = Collected()
    let echoed = Gate()
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      // Arm after the service's own presence probe, so the injected loss lands on the relay's exchange.
      await seen.probed.wait()
      fault.withLock { $0.armed = true }
      let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      let events = Task {
        for try await event in outgoing.events {
          collected.value.withLock { value in
            switch event {
            case let .output(stream, _, bytes):
              if stream == .stdout { value.stdout.append(contentsOf: bytes.bytes) } else { value.stderr.append(contentsOf: bytes.bytes) }
              if value.stdout == Data("input".utf8) { echoed.open() }
            case let .exit(status): value.status = status
            case .failed, .truncated, .timedOut: break
            }
          }
        }
      }
      defer { caller.cancel(); events.cancel(); side.release() }
      // A timed exec gets no input: an answered poll racing the timeout stop would let the relay end the exec on its own.
      if c.site != .timeout { try await outgoing.sendStdin(Array("input".utf8)) }
      // A stop is recorded before it is sent, and a poll begun after it refuses locally, so the stop paths below first wait for the
      // relay's next stdout poll to be held on the machine: the exec can then end only by the stop's verdict.
      if [.kill, .cancel, .callerGone].contains(c.site) { await seen.heldPoll.wait() }
      switch c.site {
      case .describe:
        await outgoing.closeStdin()
      case .reconcile:
        await seen.retried.wait()
        await outgoing.closeStdin()
      case .kill:
        await echoed.wait()
        do { try await hub.kill(minted.id) } catch { Issue.record("external kill failed: \(error)") }
      case .cancel:
        await echoed.wait()
        await outgoing.kill()
      case .callerGone:
        await echoed.wait()
        wall.state.withLock { $0.gone = true }
        transport.close(); caller.cancel()
      case .refused, .race, .relay, .timeout, .outputLimit:
        break
      }
      if c.site.stopReason != nil {
        await seen.retried.wait()
        side.release()
      }
      if c.site == .callerGone {
        await side.stop.wait()
      } else {
        try await events.value
      }
      let outcome = fault.withLock { $0 }
      #expect(outcome.fired); #expect(outcome.retried == (c.site != .refused))
      switch c.site {
      case .describe, .reconcile:
        #expect(collected.stdout == "input"); #expect(collected.stderr == "stderr"); #expect(collected.status == .exited(code: 7))
      case .refused:
        #expect(collected.stderr.contains("capacityExceeded")); #expect(collected.status == .exited(code: 1)); #expect(outcome.stops == 0)
      case .race:
        // Ended by the stop, not by the lost exchange.
        #expect(!collected.stderr.isEmpty); #expect(!collected.stderr.contains("transport")); #expect(!collected.stderr.contains("requestDeadline"))
        #expect(collected.status == .exited(code: 1))
      case .relay:
        #expect(collected.stderr.contains("invalidInput")); #expect(collected.status == .exited(code: 1))
      case .outputLimit:
        #expect(collected.stdout == "inp"); #expect(collected.status == .exited(code: 1))
      case .kill:
        // The kill records `cancelled`; the machine's real exit then settles the row.
        #expect(collected.status == .exited(code: 1))
      case .cancel, .timeout:
        #expect(collected.status == .exited(code: 1))
      case .callerGone:
        break
      }
      // A retry of a lost stop, reconcile or describe happens inside the exchange that lost it, before the exec ends. Only the race
      // (the kill already ended the exec record) and the relay failure (reported before its cleanup stop) retry after.
      if ![.race, .relay, .refused].contains(c.site) { #expect(outcome.terminalAtRetry == "live" || outcome.terminalAtRetry == "cancelled", "retried after the exec ended: \(outcome.terminalAtRetry ?? "-")") }
      if let reason = c.site.stopReason {
        await side.stop.wait()
        #expect(side.stopped.withLock { $0 } == reason)
      } else {
        #expect(side.stopped.withLock { $0 } == nil)
      }
      await agent.shutdown(); await service.shutdown()
    }
  }

  /// The hard budget: a timed exec whose stops are all lost still ends by its timeout plus the stop grace, rather than by a fresh
  /// retry window started after a long exchange. The same deadline bounds an external kill, and a kill that lands while the start is
  /// in flight, so neither holds `kill` or the exec past it.
  @Test(arguments: ["timeout", "kill", "race"])
  func timedExecWhoseStopsAreLostEndsWithinTheGrace(_ path: String) async throws {
    try await MachineV2Service.$timeoutStopGrace.withValue(.seconds(5)) { try await runLostStops(path) }
  }

  /// A stop after the answer is not bound by the exec's deadline: every stop is lost until after the caller has been answered at
  /// its timeout plus the stop grace, and the relay's later stop still reaches the machine, with the intent the timeout recorded.
  @Test func stopAfterTheAnswerGetsItsOwnWindow() async throws {
    try await MachineV2Service.$timeoutStopGrace.withValue(.seconds(2)) { try await runLostStops("late") }
  }

  /// A failure before any operation was claimed keeps its own message even when it comes after the timeout: nothing was stopped,
  /// so the exit status is not unknown. The relay runs on a `VirtualClock`; the admission's describe is answered with a refusal
  /// only once that clock is past the exec's timeout.
  @Test func aSetupFailureAfterTheTimeoutKeepsItsOwnMessage() async throws {
    let clock = VirtualClock()
    try await withDependencies { $0.continuousClock = clock } operation: { try await runSetupFailure(clock: clock) }
  }

  private func runSetupFailure(clock: VirtualClock) async throws {
    let probed = Gate(), describing = Gate(), overdue = Gate()
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "slow_describe_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(HeldEcho(side: MachineSide()))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { request in
      let describe = request.method == .get && !request.url.path.contains("/operations/") && request.url.path.hasSuffix(record.id.rawValue)
      if describe, probed.isOpen {
        describing.open()
        await overdue.wait()
        return try refusal(.machineNotAuthorized, for: request)
      }
      let response = try await agent.handler(request)
      if describe { probed.open() }
      return response
    } })
    await hub.configureV2(service)
    let minted = try await space.mintExec(machine: record.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["echo-test"], timeout: 1))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      await probed.wait()
      let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      defer { caller.cancel() }
      await describing.wait()
      let past = VirtualClock.at(.milliseconds(1500))
      try await clock.run(through: past) { try await clock.sleep(until: past) }
      overdue.open()
      var stderr = Data(); var status: MachineContract.ExitStatus?; var timedOut = false
      for try await event in outgoing.events {
        switch event {
        case let .output(stream, _, bytes): if stream == .stderr { stderr.append(contentsOf: bytes.bytes) }
        case let .exit(value): status = value
        case .timedOut: timedOut = true
        case .failed, .truncated: break
        }
      }
      #expect(String(decoding: stderr, as: UTF8.self).hasPrefix("machineNotAuthorized: "), "\(String(decoding: stderr, as: UTF8.self))")
      #expect(status == .exited(code: 1))
      #expect(!timedOut)
      #expect(try await space.execRecord(minted.id)?.terminal == .exited(code: 1))
      await agent.shutdown(); await service.shutdown()
    }
  }

  /// Runs the relay on a `VirtualClock`, so the bounds hold however slow the host is: time moves only from one of the relay's
  /// sleeps to the next and never past the bound under test, so a relay that needed longer would never answer.
  private func runLostStops(_ path: String) async throws {
    let clock = VirtualClock()
    try await withDependencies { $0.continuousClock = clock } operation: { try await runLostStops(path, clock: clock) }
  }

  private func runLostStops(_ path: String, clock: VirtualClock) async throws {
    let execID = Mutex<ExecID?>(nil)
    let losing = Mutex(true)
    let lostStops = LostStops()
    let started = Gate()
    let polled = Gate()
    let side = MachineSide()
    let space = try Space.inMemory()
    let key = SymmetricKey(size: .bits256)
    // The clock stands still until the start has reached the machine, after the exec was admitted with its deadline: its caller
    // must be answered by its timeout plus the stop grace from there.
    let answerBy = VirtualClock.at(.seconds(1) + MachineV2Service.timeoutStopGrace)
    let (record, _) = try await space.addMachineV2(name: "retry_bound_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(HeldEcho(side: side))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: key, failure: nil, fetch: { _ in FetchClient { request in
      if request.method == .put, request.url.path.hasSuffix("/stop"), losing.withLock({ $0 }) { lostStops.lost(); throw LostExchange() }
      if request.method == .post, request.url.path.contains("/operations/") {
        started.open()
        if path == "race", let id = execID.withLock({ $0 }) { try await hub.kill(id) }
      }
      if request.method == .get, request.url.query?.contains("channel=stdout") == true { polled.open() }
      return try await agent.handler(request)
    } })
    await hub.configureV2(service)
    let minted = try await space.mintExec(machine: record.id, group: .shared)
    execID.withLock { $0 = minted.id }
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["echo-test"], timeout: 1))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      defer { caller.cancel() }
      await started.wait()
      // The kill lands on a running operation, once the relay polls its output, before time moves.
      if path == "kill" {
        await polled.wait()
        try? await hub.kill(minted.id)
      }
      let status = try await clock.run(through: answerBy) {
        var status: MachineContract.ExitStatus?
        for try await event in outgoing.events { if case let .exit(value) = event { status = value } }
        return status
      }
      #expect(status == .exited(code: 1))
      if path == "timeout" || path == "late" { #expect(clock.now >= VirtualClock.at(.seconds(1))) }
      #expect(side.stopped.withLock { $0 } == nil)
      if path == "late" {
        // Still lost past the answer, so the stop's retries outlast the exec's spent deadline.
        lostStops.answered()
        await lostStops.twiceAfterTheAnswer.wait()
        losing.withLock { $0 = false }
        await side.stop.wait()
        #expect(side.stopped.withLock { $0 } == MachineV2Service.timeoutStop)
        let store = try await space.machineV2Store(group: .shared, key: key)
        let operation = try await store.lookup(OperationOwner(scope: "exec/" + minted.id.rawValue, key: minted.id.rawValue))
        #expect(operation?.stopReason == MachineV2Service.timeoutStop)
        side.release()
      }
      await agent.shutdown(); await service.shutdown()
    }
  }
}

extension Optional {
  fileprivate func asyncMap<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
    guard let self else { return nil }
    return try await transform(self)
  }
}
