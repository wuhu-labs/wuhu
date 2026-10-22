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
import FetchTunnel
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import OperationClient
import OperationProtocol
@testable import OperationRuntime
import Serve
import struct SpaceContract.GroupID
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

/// What the machine side of these tests shares with the test: a gate the process waits on, and the stop reasons it saw.
private final class MachineSide: Sendable {
  let finished = Gate()
  let opened = Mutex(false)
  let reasons = Mutex<[String]>([])
  /// One element per `t` a `ticks` process writes, for whoever is waiting right then.
  let ticks = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(0))
  var open: Bool { opened.withLock { $0 } }
  func release() { opened.withLock { $0 = true }; finished.open() }
}

/// An exec kind whose first argument picks how the process behaves:
/// - `exit <text>` writes text and exits 3;
/// - `hold <text>` writes text, runs until stopped, then ends killed by signal 15, as the supervisor reports a stopped process;
/// - `gate <first> <second>` writes first, waits for the gate, writes second and exits 5;
/// - `ticks` writes `t` every 50 ms and ignores stops until the gate opens.
private struct ScriptedProcess: OperationKind {
  let side: MachineSide
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec

  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    let argv = input.argv
    func write(_ text: String) async throws { try await channels.send(.init(data: Data(text.utf8)), to: "stdout") }
    switch argv.first {
    case "exit":
      try await write(argv[1])
      return ["termination": ["tag": "exit", "code": 3]]
    case "gate":
      try await write(argv[1])
      while !side.open { try await Task.sleep(for: .milliseconds(10)) }
      try await write(argv[2])
      return ["termination": ["tag": "exit", "code": 5]]
    case "prefix":
      try await write("abcdef")
      await side.finished.wait()
      try Task.checkCancellation()
      return ["termination": ["tag": "exit", "code": 5]]
    case "cut":
      try await write("tttt")
      await side.finished.wait()
      try Task.checkCancellation()
      return ["termination": ["tag": "signal", "signal": 9]]
    case "ticks":
      while !side.open {
        try? await write("t")
        side.ticks.continuation.yield()
        try? await Task.sleep(for: .milliseconds(50))
      }
      return ["termination": ["tag": "signal", "signal": 9]]
    default:
      try await write(argv[1])
      while true {
        if let reason = await cancellation.reason() {
          side.reasons.withLock { $0.append(reason) }
          return ["termination": ["tag": "signal", "signal": 15]]
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
  }
}

/// Everything the caller saw, in order.
private final class Events: Sendable {
  let log = Mutex<[ExecEvent]>([])
  /// Opens once stdout output has reached the caller.
  let firstStdout = Gate()
  func follow(_ outgoing: OutgoingExec) -> Task<Void, Never> {
    Task {
      do {
        for try await event in outgoing.events {
          log.withLock { $0.append(event) }
          if case .output(.stdout, _, _) = event { firstStdout.open() }
        }
      } catch {}
    }
  }

  func text(_ wanted: ExecOutputStream) -> String {
    log.withLock { log in
      log.reduce(into: "") { text, event in
        if case let .output(stream, _, data) = event, stream == wanted { text += String(decoding: data.bytes, as: UTF8.self) }
      }
    }
  }

  var stdout: String { text(.stdout) }
  var stderr: String { text(.stderr) }
  var status: MachineContract.ExitStatus? { log.withLock { $0.lazy.compactMap { if case let .exit(status) = $0 { status } else { nil } }.first } }
  var timedOut: ExecTimeout? { log.withLock { $0.lazy.compactMap { if case let .timedOut(outcome) = $0 { outcome } else { nil } }.first } }
  var truncated: Bool { log.withLock { $0.contains { if case .truncated = $0 { true } else { false } } } }
}

private func eventually(_ seconds: Double = 15, _ condition: () async throws -> Bool) async throws -> Bool {
  let end = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < end {
    if try await condition() { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return try await condition()
}

/// The wall clock the services read, moved forward by hand.
private final class Wall: Sendable {
  let offset = Mutex<TimeInterval>(0)
}

/// A store whose `live` fails while `failures` is above zero, one failure each, as a database briefly unavailable at boot does.
private final class FlakyLive: OperationStore, Sendable {
  let base: any OperationStore
  let failures: Mutex<Int>
  init(base: any OperationStore, failures: Int) { self.base = base; self.failures = Mutex(failures) }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] {
    let fail = failures.withLock { left in
      guard left > 0 else { return false }
      left -= 1; return true
    }
    if fail { throw OperationError(.storeUnavailable, message: "database is locked") }
    return try await base.live()
  }

  func setAside(_ id: UUID) async throws { try await base.setAside(id) }

  func save(_ record: ClientRecord, appending chunk: OperationClient.OutputChunk?) async throws { try await base.save(record, appending: chunk) }
  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws { try await base.trim(record, removing: sequences) }
}

/// A store that refuses every write of one record, as it refuses a record whose start no longer matches its digest.
private final class RefusingWrites: OperationStore, Sendable {
  let base: any OperationStore
  let refused: UUID
  init(base: any OperationStore, refused: UUID) { self.base = base; self.refused = refused }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] { try await base.live() }
  func setAside(_ id: UUID) async throws { try await base.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OperationClient.OutputChunk?) async throws {
    guard record.id != refused else { throw OperationError(.invocationConflict, operation: refused) }
    try await base.save(record, appending: chunk)
  }

  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws {
    guard record.id != refused else { throw OperationError(.invocationConflict, operation: refused) }
    try await base.trim(record, removing: sequences)
  }
}

/// A dying caller leg that loses output after its admitted prefix (all output by default).
private struct LosingOutput: FrameTransport {
  let base: any FrameTransport
  let inbound: AsyncStream<[UInt8]>
  init(_ base: any FrameTransport, retainingPrefix: Int = 0) {
    self.base = base
    inbound = AsyncStream { continuation in
      let task = Task {
        for await bytes in base.inbound {
          if let frame = try? FrameCodec.decode(bytes), frame.opcode == .output,
             let chunk = try? frame.payload(MachineContract.OutputChunk.self), chunk.cursor >= retainingPrefix { continue }
          continuation.yield(bytes)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func send(_ frame: [UInt8]) async throws { try await base.send(frame) }
  func close() { base.close() }
}

/// A caller leg to the exec as `leg`, attached through the hub as the exec route attaches one.
private func connect(_ record: ExecRecord, hub: MachineHub, as leg: ExecLeg) -> WebSocketTransport {
  let (server, client) = WebSocket.pair()
  Task { await hub.runCallerSession(record, socket: server, leg: leg) }
  return WebSocketTransport(client)
}

/// One v2 machine in an in-memory space, its in-process agent, and the server's hub and service in front of it.
private struct Rig {
  let space: Space
  let machine: MachineRecord
  let side = MachineSide()
  let agent: OperationAgent
  let key = SymmetricKey(size: .bits256)

  init() async throws {
    space = try Space.inMemory()
    machine = try await space.addMachineV2(name: "lifecycle_v2", group: .shared).machine
    agent = try OperationAgent(machine: machine.id.rawValue, kinds: [.init(ScriptedProcess(side: side))], authorize: { _, _ in })
  }

  /// A service reaching the agent directly, `fetch` seeing each request first.
  func service(_ fetch: @escaping @Sendable (Request) async throws -> Void = { _ in }) -> MachineV2Service {
    let agent = agent
    return MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: key, failure: nil, fetch: { _ in FetchClient { request in
      try await fetch(request)
      return try await agent.handler(request)
    } })
  }

  /// The service a restart brings up over the same space; `stores` replaces the space's operation stores.
  func reopen(stores: (@Sendable (GroupID) async throws -> any OperationStore)? = nil) async -> MachineV2Service {
    let agent = agent
    return await MachineV2Service.open(space: space, hub: MachineV2Hub(space: space), key: key, fetch: { _ in FetchClient { try await agent.handler($0) } }, stores: stores)
  }

  /// Runs a first service with the exec's caller attached through `leg` until `ready`, then takes the service down as a
  /// restart does, the caller's connection with it.
  func serveUntilRestart(
    _ minted: ExecRecord, endpoint: ChannelEndpoint, leg: (any FrameTransport) -> any FrameTransport = { $0 },
    until ready: (MachineV2Service) async throws -> Bool,
  ) async throws {
    let first = service()
    let hub = MachineHub(space: space)
    await hub.configureV2(first)
    let running = Task { try await first.run() }
    let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
    let attached = leg(transport)
    let caller = Task { await endpoint.run(attached) }
    #expect(try await eventually { try await ready(first) })
    await first.shutdown()
    running.cancel()
    transport.close(); caller.cancel()
    _ = await caller.value
  }

  /// An exec-owned operation opened the way a server from before execs kept their relay state opened it: without that state.
  func openWithoutRelayState(_ minted: ExecRecord, command: [String], in service: MachineV2Service) async throws -> OperationClient.Operation {
    let start = StartRequest(kind: "exec.v1", input: ["argv": .array(command.map(JSONValue.string)), "cwd": "/tmp", "stdin": false])
    return try await service.operations(group: minted.group).open(.init(scope: "exec/" + minted.id.rawValue, key: minted.id.rawValue), machine: machine.id.rawValue, start: start)
  }

  /// The exec's operation as the service's store keeps it.
  func stored(_ exec: ExecRecord, in service: MachineV2Service) async throws -> ClientRecord? {
    try await service.operations(group: exec.group).lookup(.init(scope: "exec/" + exec.id.rawValue, key: exec.id.rawValue))
  }
}

@Suite(.deterministicDependencies(clock: ContinuousClock()), .timeLimit(.minutes(2))) struct MachineV2ExecLifecycleTests {
  /// Audit 8: each way an exec ends reaches the caller as the process's own status and the record as the reason it ended. A
  /// stop the caller's side asked for (a kill, the caller's cancel, the caller gone) records `cancelled`; the timeout and the
  /// output budget keep the process's real termination.
  @Test(arguments: ["completed", "callerCancelled", "kill", "timeout", "outputLimit"])
  func everyEndingReachesTheCallerAndTheRecordAsItsOwn(_ ending: String) async throws {
    try await MachineV2Service.$callerGrace.withValue(.seconds(2)) { try await end(ending) }
  }

  @Test func callerGoneReachesTheRecordAfterWallClockGrace() async throws {
    try await withDependencies {
      $0.date = DateGenerator { Date() }
    } operation: {
      try await MachineV2Service.$callerGrace.withValue(.seconds(2)) { try await end("callerGone") }
    }
  }

  private func end(_ ending: String) async throws {
    let rig = try await Rig()
    let hub = MachineHub(space: rig.space)
    let service = rig.service()
    await hub.configureV2(service)
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let command = ending == "completed" ? ["exit", "out"] : ["hold", ending == "outputLimit" ? "abcdef" : "x"]
    let outgoing = await endpoint.startExec(.init(
      id: minted.id, cwd: "/tmp", command: command, maxOutput: ending == "outputLimit" ? 3 : nil, timeout: ending == "timeout" ? 1 : 30,
    ))
    let events = Events()
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let transport = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      let following = events.follow(outgoing)
      defer { caller.cancel(); following.cancel() }
      if ["callerCancelled", "kill", "callerGone"].contains(ending) { #expect(try await eventually { events.stdout == "x" }) }
      switch ending {
      case "callerCancelled": await outgoing.kill()
      case "kill": try await hub.kill(minted.id)
      case "callerGone": transport.close(); caller.cancel()
      default: break
      }
      #expect(try await eventually { try await rig.space.execRecord(minted.id)?.terminal != nil })
      if ending != "callerGone" { #expect(try await eventually { events.status != nil }) }
      let terminal = try await rig.space.execRecord(minted.id)?.terminal
      switch ending {
      case "completed":
        #expect(events.stdout == "out"); #expect(events.status == .exited(code: 3)); #expect(terminal == .exited(code: 3))
        #expect(rig.side.reasons.withLock { $0 }.isEmpty)
      case "callerCancelled", "kill":
        #expect(events.status == .signaled(signal: 15)); #expect(terminal == .cancelled)
      case "callerGone":
        #expect(terminal == .cancelled)
      case "timeout":
        #expect(events.status == .signaled(signal: 15)); #expect(events.timedOut == .killed); #expect(terminal == .signaled(signal: 15))
      default:
        #expect(events.stdout == "abc"); #expect(events.truncated)
        #expect(events.status == .signaled(signal: 15)); #expect(terminal == .signaled(signal: 15))
      }
      if ending != "completed" {
        let reason = ending == "kill" ? "callerCancelled" : ending
        #expect(try await eventually { rig.side.reasons.withLock { $0 } == [reason] })
      }
      if ending != "timeout" { #expect(events.timedOut == nil) }
      await rig.agent.shutdown(); await service.shutdown()
    }
  }

  /// Audit 15 and 16: what the service keeps about an exec or a machine goes away on its own timer, with no further traffic: a
  /// finished exec's endpoint after its retention, a minted exec nobody connected to after the caller grace, and a machine's
  /// cached description as soon as it leaves the group.
  @Test func endpointsAndDescriptionsGoAwayWithoutTraffic() async throws {
    try await MachineV2Service.$endpointRetention.withValue(.seconds(1)) {
      try await MachineV2Service.$callerGrace.withValue(.seconds(1)) { try await expire() }
    }
  }

  private func expire() async throws {
    let rig = try await Rig()
    let hub = MachineHub(space: rig.space)
    let service = rig.service()
    await hub.configureV2(service)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let operations = try await service.operations(group: .shared)
      #expect(try await eventually { await operations.recentDescription(rig.machine.id.rawValue) != nil })

      let finished = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(.init(id: finished.id, cwd: "/tmp", command: ["exit", "out"], timeout: 30))
      let transport = try await connectExecCaller(finished.id, space: rig.space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      defer { caller.cancel() }
      var status: MachineContract.ExitStatus?
      for try await event in outgoing.events { if case let .exit(value) = event { status = value } }
      #expect(status == .exited(code: 3))
      #expect(await service.execEndpoints[finished.id.rawValue] != nil)
      #expect(try await eventually(5) { await service.execEndpoints[finished.id.rawValue] == nil })

      let unconnected = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
      await hub.noteMinted(unconnected)
      #expect(try await eventually(5) { try await rig.space.execRecord(unconnected.id)?.terminal == .reaped })
      #expect(await service.execEndpoints[unconnected.id.rawValue] == nil)

      let person = try await rig.space.addAccount(kind: .human, name: "elsewhere", admin: false)
      let group = try await rig.space.ensurePersonalGroup(account: person.id)
      _ = try await rig.space.moveMachine(rig.machine.id, to: group)
      #expect(try await eventually(5) { await operations.recentDescription(rig.machine.id.rawValue) == nil })
      let moved = try await service.operations(group: group)
      #expect(try await eventually(5) { await moved.recentDescription(rig.machine.id.rawValue) != nil })
      await rig.agent.shutdown(); await service.shutdown()
    }
  }

  /// The machine keeps an exec's output until the caller's endpoint holds it: a finished process whose caller is not reading
  /// is never acknowledged as settled, with or without an output budget queueing its output, and every byte arrives once the
  /// caller reads.
  @Test(arguments: [nil, 100] as [Int?])
  func theMachineKeepsOutputUntilTheCallerHoldsIt(maxOutput: Int?) async throws {
    let rig = try await Rig()
    let settles = Mutex(0)
    let hub = MachineHub(space: rig.space)
    let service = rig.service { request in
      if request.url.query?.contains("terminalAck=") == true { settles.withLock { $0 += 1 } }
    }
    await hub.configureV2(service)
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["exit", "abcdefghij"], window: 4, maxOutput: maxOutput, timeout: 30))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let transport = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      defer { caller.cancel() }
      #expect(try await eventually { await rig.agent.operations.values.contains { $0.verdict != nil } })
      try await Task.sleep(for: .seconds(1))
      #expect(settles.withLock { $0 } == 0)
      #expect(try await rig.space.execRecord(minted.id)?.terminal == nil)
      let events = Events()
      await events.follow(outgoing).value
      #expect(events.stdout == "abcdefghij"); #expect(events.status == .exited(code: 3)); #expect(!events.truncated)
      let operations = try await service.operations(group: .shared)
      #expect(try await eventually { await operations.running == 0 })
      #expect(settles.withLock { $0 } > 0)
      await rig.agent.shutdown(); await service.shutdown()
    }
  }

  /// Once the caller is told a timed-out exec's status is unknown, nothing more reaches it, though the process keeps writing.
  /// The relay runs on a `VirtualClock` that stands still until the first output has reached the caller.
  @Test func nothingReachesTheCallerAfterAnUnresolvedTimeout() async throws {
    let clock = VirtualClock()
    try await MachineV2Service.$timeoutStopGrace.withValue(.seconds(1)) {
      let rig = try await Rig()
      let hub = MachineHub(space: rig.space)
      let service = rig.service()
      await hub.configureV2(service)
      let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["ticks"], timeout: 1))
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await rig.agent.run() }
        tasks.addTask { try await withDependencies { $0.continuousClock = clock } operation: { try await service.run() } }
        defer { tasks.cancelAll(); rig.side.release() }
        let transport = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
        let caller = Task { await endpoint.run(transport) }
        defer { caller.cancel() }
        let events = Events()
        let following = events.follow(outgoing)
        await events.firstStdout.wait()
        try await clock.run(through: VirtualClock.at(.seconds(1) + MachineV2Service.timeoutStopGrace)) { await following.value }
        // The process keeps writing past the answer.
        var ticks = rig.side.ticks.stream.makeAsyncIterator()
        for _ in 0 ..< 3 { await ticks.next() }
        let log = events.log.withLock { $0 }
        let answer = try #require(log.firstIndex {
          if case let .output(.stderr, _, data) = $0 { String(decoding: data.bytes, as: UTF8.self).hasPrefix("requestDeadline: ") } else { false }
        })
        #expect(log[..<answer].contains { if case .output(.stdout, _, _) = $0 { true } else { false } })
        #expect(!log[(answer + 1)...].contains { if case .output = $0 { true } else { false } })
        #expect(events.status == .exited(code: 1)); #expect(events.timedOut == .statusUnknown)
        #expect(try await rig.space.execRecord(minted.id)?.terminal == .machineLost)
        rig.side.release()
        await rig.agent.shutdown(); await service.shutdown()
      }
    }
  }

  /// Audit 4: an exec outlives a server restart. The next service resumes its operation from the store, the caller's endpoint
  /// reconnects, and the caller gets every byte once and the process's own exit.
  @Test func anExecOutlivesAServerRestart() async throws {
    let rig = try await Rig()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "before", "after"], timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }

      let first = rig.service()
      let firstHub = MachineHub(space: rig.space)
      await firstHub.configureV2(first)
      let running = Task { try await first.run() }
      let firstLeg = try await connectExecCaller(minted.id, space: rig.space, hub: firstHub)
      let firstCaller = Task { await endpoint.run(firstLeg) }
      #expect(try await eventually { events.stdout == "before" })
      await first.shutdown()
      running.cancel()
      firstLeg.close(); firstCaller.cancel()
      _ = await firstCaller.value

      rig.side.release()
      let agent = rig.agent
      let second = await MachineV2Service.open(space: rig.space, hub: MachineV2Hub(space: rig.space), key: rig.key, fetch: { _ in FetchClient { try await agent.handler($0) } })
      let secondHub = MachineHub(space: rig.space)
      await secondHub.configureV2(second)
      tasks.addTask { try await second.run() }
      let secondLeg = try await connectExecCaller(minted.id, space: rig.space, hub: secondHub)
      let secondCaller = Task { await endpoint.run(secondLeg) }
      defer { secondCaller.cancel() }
      _ = await following.value
      #expect(events.stdout == "beforeafter")
      #expect(events.status == .exited(code: 5))
      #expect(try await rig.space.execRecord(minted.id)?.terminal == .exited(code: 5))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  /// A restart keeps who holds an exec: a callerless exec one person started is not taken by another person who reaches it
  /// first after the restart, and its holder reads it to its end.
  @Test func aRestartKeepsTheExecsHolder() async throws {
    let rig = try await Rig()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let holder = ExecLeg.person(AccountID(rawValue: "ac_holder01"))
    let other = ExecLeg.person(AccountID(rawValue: "ac_other001"))
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "before", "after"], timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      let first = rig.service()
      let firstHub = MachineHub(space: rig.space)
      await firstHub.configureV2(first)
      let running = Task { try await first.run() }
      let firstLeg = connect(minted, hub: firstHub, as: holder)
      let firstCaller = Task { await endpoint.run(firstLeg) }
      #expect(try await eventually { events.stdout == "before" })
      await first.shutdown()
      running.cancel()
      firstLeg.close(); firstCaller.cancel()
      _ = await firstCaller.value

      let second = await rig.reopen()
      let secondHub = MachineHub(space: rig.space)
      await secondHub.configureV2(second)
      tasks.addTask { try await second.run() }
      #expect(await secondHub.admitsCaller(minted, leg: other) == false)
      // The other person's start, sent anyway, reaches nothing.
      let intruder = ChannelEndpoint()
      let intruding = await intruder.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "before", "after"], timeout: 60))
      let seen = Events()
      let watching = seen.follow(intruding)
      let intruderCaller = Task { await intruder.run(connect(minted, hub: secondHub, as: other)) }
      try await Task.sleep(for: .milliseconds(300))
      #expect(seen.stdout.isEmpty)
      intruderCaller.cancel(); watching.cancel()
      #expect(await secondHub.admitsCaller(minted, leg: holder))

      rig.side.release()
      let secondCaller = Task { await endpoint.run(connect(minted, hub: secondHub, as: holder)) }
      defer { secondCaller.cancel() }
      _ = await following.value
      #expect(events.stdout == "beforeafter")
      #expect(events.status == .exited(code: 5))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  /// Output cut at the exec's budget stays cut across a restart: the caller, holding exactly the admitted bytes, gets the
  /// process's exit with the truncation, and nothing of the discarded output.
  @Test(arguments: [false, true])
  func outputCutBeforeARestartEndsWhereTheCallerHasIt(holdConsumption: Bool) async throws {
    let rig = try await Rig()
    let store = HeldConsumption(base: try await rig.space.machineV2Store(group: .shared, key: rig.key, problemsGroup: MachineV2Service.problemsGroup))
    defer { store.release.open() }
    if !holdConsumption { store.release.open() }
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["cut"], maxOutput: 3, timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel(); rig.side.release() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      let first = await rig.reopen(stores: { _ in store })
      let firstHub = MachineHub(space: rig.space)
      await firstHub.configureV2(first)
      let running = Task { try await first.run() }
      let firstLeg = try await connectExecCaller(minted.id, space: rig.space, hub: firstHub)
      let firstCaller = Task { await endpoint.run(firstLeg) }
      await events.firstStdout.wait()
      await store.saving.wait()
      if holdConsumption {
        let id = try #require(store.operation.withLock { $0 })
        let retained = try await store.base.read(id)
        #expect(!retained.output.isEmpty)
        #expect(!retained.discard)
        #expect(!store.discarded.isOpen)
        store.release.open()
      }
      await store.discarded.wait()
      await first.shutdown()
      running.cancel()
      _ = try? await running.value
      firstLeg.close(); firstCaller.cancel()
      _ = await firstCaller.value

      let second = await rig.reopen()
      let secondHub = MachineHub(space: rig.space)
      await secondHub.configureV2(second)
      tasks.addTask { try await second.run() }
      let secondLeg = try await connectExecCaller(minted.id, space: rig.space, hub: secondHub)
      let secondCaller = Task { await endpoint.run(secondLeg) }
      defer { secondCaller.cancel() }
      rig.side.release()
      _ = await following.value
      #expect(events.stdout == "ttt")
      #expect(events.truncated)
      #expect(events.status == .signaled(signal: 9))
      #expect(try await rig.space.execRecord(minted.id)?.terminal == .signaled(signal: 9))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  @Test func aPartlyAcknowledgedChunkResumesWithoutDuplicatingItsPrefix() async throws {
    let rig = try await Rig()
    let store = HeldConsumption(base: try await rig.space.machineV2Store(group: .shared, key: rig.key, problemsGroup: MachineV2Service.problemsGroup))
    store.release.open()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["prefix"], window: 3, maxOutput: 10, timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel(); rig.side.release() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      let first = await rig.reopen(stores: { _ in store })
      let firstHub = MachineHub(space: rig.space)
      await firstHub.configureV2(first)
      let running = Task { try await first.run() }
      let firstLeg = try await connectExecCaller(minted.id, space: rig.space, hub: firstHub)
      let losing = LosingOutput(firstLeg, retainingPrefix: 3)
      let firstCaller = Task { await endpoint.run(losing) }
      await events.firstStdout.wait()
      await store.saved.wait()
      #expect(events.stdout == "abc")
      let id = try #require(store.operation.withLock { $0 })
      #expect(try await store.base.read(id).discard == false)
      await first.shutdown()
      running.cancel()
      _ = try? await running.value
      firstLeg.close(); firstCaller.cancel()
      _ = await firstCaller.value

      let second = await rig.reopen()
      let secondHub = MachineHub(space: rig.space)
      await secondHub.configureV2(second)
      tasks.addTask { try await second.run() }
      let secondLeg = try await connectExecCaller(minted.id, space: rig.space, hub: secondHub)
      let secondCaller = Task { await endpoint.run(secondLeg) }
      defer { secondCaller.cancel() }
      rig.side.release()
      _ = await following.value
      #expect(events.stdout == "abcdef")
      #expect(!events.truncated)
      #expect(events.status == .exited(code: 5))
      #expect(try await rig.space.execRecord(minted.id)?.terminal == .exited(code: 5))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  /// A restart resumes a timed exec's deadline, not a fresh timeout: an exec most of whose timeout passed before the restart
  /// is stopped at the rest of it, whether or not its caller is back by then.
  @Test func aRestartKeepsTheExecsDeadline() async throws {
    let wall = Wall()
    try await withDependencies { $0.date = DateGenerator { Date().addingTimeInterval(wall.offset.withLock { $0 }) } } operation: {
      let rig = try await Rig()
      let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["hold", "x"], timeout: 60))
      let events = Events()
      let following = events.follow(outgoing)
      defer { following.cancel() }
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await rig.agent.run() }
        defer { tasks.cancelAll() }
        let first = rig.service()
        let firstHub = MachineHub(space: rig.space)
        await firstHub.configureV2(first)
        let running = Task { try await first.run() }
        let firstLeg = try await connectExecCaller(minted.id, space: rig.space, hub: firstHub)
        let firstCaller = Task { await endpoint.run(firstLeg) }
        #expect(try await eventually { events.stdout == "x" })
        await first.shutdown()
        running.cancel()
        firstLeg.close(); firstCaller.cancel()
        _ = await firstCaller.value

        // All but a second of the timeout passes while the server is down.
        wall.offset.withLock { $0 = 59 }
        let second = await rig.reopen()
        let secondHub = MachineHub(space: rig.space)
        await secondHub.configureV2(second)
        tasks.addTask { try await second.run() }
        #expect(try await eventually(5) { rig.side.reasons.withLock { $0 } == ["timeout"] })
        let secondLeg = try await connectExecCaller(minted.id, space: rig.space, hub: secondHub)
        let secondCaller = Task { await endpoint.run(secondLeg) }
        defer { secondCaller.cancel() }
        #expect(try await eventually(20) { events.status != nil })
        #expect(events.status == .signaled(signal: 15))
        #expect(events.timedOut == .killed)
        #expect(rig.side.reasons.withLock { $0 } == ["timeout"])
        await rig.agent.shutdown(); await second.shutdown()
      }
    }
  }

  /// A group whose live operations cannot be resumed at boot, the store failing, is retried while the service runs: the
  /// service is not failed, the group's operations are refused only until then, and its exec is resumed after.
  @Test func aFailedRecoveryIsRetried() async throws {
    let rig = try await Rig()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "before", "after"], timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      let first = rig.service()
      let firstHub = MachineHub(space: rig.space)
      await firstHub.configureV2(first)
      let running = Task { try await first.run() }
      let firstLeg = try await connectExecCaller(minted.id, space: rig.space, hub: firstHub)
      let firstCaller = Task { await endpoint.run(firstLeg) }
      #expect(try await eventually { events.stdout == "before" })
      await first.shutdown()
      running.cancel()
      firstLeg.close(); firstCaller.cancel()
      _ = await firstCaller.value

      let space = rig.space, key = rig.key
      let second = await rig.reopen { group in
        FlakyLive(base: try await space.machineV2Store(group: group, key: key, problemsGroup: MachineV2Service.problemsGroup), failures: 1)
      }
      #expect(await second.recovered(.shared) == false)
      await #expect { _ = try await second.operations(group: .shared) } throws: { ($0 as? OperationError)?.code == .storeUnavailable }
      let secondHub = MachineHub(space: rig.space)
      await secondHub.configureV2(second)
      tasks.addTask { try await second.run() }
      #expect(try await eventually { await second.recovered(.shared) })
      rig.side.release()
      let secondLeg = try await connectExecCaller(minted.id, space: rig.space, hub: secondHub)
      let secondCaller = Task { await endpoint.run(secondLeg) }
      defer { secondCaller.cancel() }
      _ = await following.value
      #expect(events.stdout == "beforeafter")
      #expect(events.status == .exited(code: 5))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }
}

/// Two in-memory tunnel transports joined back to back.
private final class Link: Sendable {
  let first: TunnelTransport
  let second: TunnelTransport

  init() {
    let (toFirst, intoFirst) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let (toSecond, intoSecond) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let readFirst = Reader(toFirst), readSecond = Reader(toSecond)
    let abort: @Sendable () -> Void = { intoFirst.finish(); intoSecond.finish() }
    first = TunnelTransport(receive: { try await readFirst.next() }, send: { intoSecond.yield($0) }, abort: abort)
    second = TunnelTransport(receive: { try await readSecond.next() }, send: { intoFirst.yield($0) }, abort: abort)
  }
}

private actor Reader {
  var iterator: AsyncThrowingStream<Bytes, any Error>.Iterator
  init(_ stream: AsyncThrowingStream<Bytes, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    var iterator = self.iterator
    let result = try await iterator.next(isolation: self)
    self.iterator = iterator
    return result
  }
}

extension MachineV2ExecLifecycleTests {
  /// Audit 1: forty execs at once through a real tunnel. A machine that advertises the full tunnel runs them all; one that does
  /// not (32 streams) runs the ones that fit and refuses the rest with a typed capacity error at their start. None hangs.
  @Test(arguments: [MachineV2Connect.tunnelStreams, TunnelLimits().streams])
  func fortyExecsThroughARealTunnel(streams: Int) async throws {
    let space = try Space.inMemory()
    let signing = Curve25519.Signing.PrivateKey()
    let machine = try await space.enrollMachineV2(name: "tunnel_v2", group: .shared, pubkey: signing.pubkeyLabel).machine
    let side = MachineSide()
    let agent = try OperationAgent(machine: machine.id.rawValue, kinds: [.init(ScriptedProcess(side: side))], authorize: { _, _ in })
    let tunnelHub = MachineV2Hub(space: space)
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: tunnelHub, key: SymmetricKey(size: .bits256), failure: nil)
    await hub.configureV2(service)
    let link = Link()
    let count = 40
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      tasks.addTask { await tunnelHub.run(.init(pubkey: signing.pubkeyLabel, machines: [machine.id.rawValue]), transport: link.second, streams: streams) }
      tasks.addTask { try await Tunnel.serve(over: link.first, limits: .init(streams: streams), handler: agent.handler) }
      defer { tasks.cancelAll(); side.release() }
      #expect(try await eventually { await tunnelHub.streams(machine.id.rawValue) == streams })
      var execs: [(endpoint: ChannelEndpoint, events: Events, follow: Task<Void, Never>, caller: Task<Void, Never>)] = []
      for index in 0 ..< count {
        let minted = try await space.mintExec(machine: machine.id, group: .shared)
        let endpoint = ChannelEndpoint()
        let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "a\(index)", "b\(index)"], timeout: 60))
        let events = Events()
        let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
        execs.append((endpoint, events, events.follow(outgoing), Task { await endpoint.run(transport) }))
      }
      defer { for exec in execs { exec.caller.cancel(); exec.follow.cancel() } }
      // Every exec is running or refused before any may finish.
      #expect(try await eventually(30) {
        execs.enumerated().allSatisfy { index, exec in exec.events.stdout == "a\(index)" || exec.events.status != nil }
      })
      side.release()
      for exec in execs { _ = await exec.follow.value }
      var ran = 0
      for (index, exec) in execs.enumerated() {
        if exec.events.status == .exited(code: 5) {
          #expect(exec.events.stdout == "a\(index)b\(index)")
          ran += 1
        } else {
          #expect(exec.events.status == .exited(code: 1))
          #expect(exec.events.stderr.hasPrefix("capacityExceeded: "), "\(exec.events.stderr)")
        }
      }
      // Each exec holds one control and two output lanes; describes keep their own.
      #expect(ran == min(count, (streams - 2) / 3))
      await agent.shutdown(); await service.shutdown()
    }
  }
}

extension MachineV2ExecLifecycleTests {
  /// Output cut at the budget is kept until the caller holds it, not merely until it was sent: the admitted bytes, lost on the
  /// way with the caller's old connection, still reach the caller after a restart, with the exit and the truncation.
  @Test func aCutPrefixTheCallerNeverGotArrivesAfterARestart() async throws {
    let rig = try await Rig()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["ticks"], maxOutput: 3, timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel(); rig.side.release() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      try await rig.serveUntilRestart(minted, endpoint: endpoint, leg: { LosingOutput($0) }) { first in
        try await rig.stored(minted, in: first)?.stopReason == "outputLimit"
      }
      #expect(events.stdout.isEmpty)
      let second = await rig.reopen()
      let hub = MachineHub(space: rig.space)
      await hub.configureV2(second)
      tasks.addTask { try await second.run() }
      let leg = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
      let caller = Task { await endpoint.run(leg) }
      defer { caller.cancel() }
      rig.side.release()
      _ = await following.value
      #expect(events.stdout == "ttt")
      #expect(events.truncated)
      #expect(events.status == .signaled(signal: 9))
      #expect(try await rig.space.execRecord(minted.id)?.terminal == .signaled(signal: 9))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  /// A restart after a timed exec's stop grace ran out answers its caller at once with the unknown status it is owed, instead
  /// of granting the process another grace.
  @Test func aRestartPastTheTimeoutGraceAnswersAtOnce() async throws {
    let wall = Wall()
    try await withDependencies { $0.date = DateGenerator { Date().addingTimeInterval(wall.offset.withLock { $0 }) } } operation: {
      let rig = try await Rig()
      let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["ticks"], timeout: 60))
      let events = Events()
      let following = events.follow(outgoing)
      defer { following.cancel(); rig.side.release() }
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await rig.agent.run() }
        defer { tasks.cancelAll() }
        try await rig.serveUntilRestart(minted, endpoint: endpoint) { _ in events.stdout.hasPrefix("t") }
        // The server comes back after the timeout and its whole stop grace; the process ignores stops.
        wall.offset.withLock { $0 = 60 + Double(MachineV2Service.timeoutStopGrace.components.seconds) + 5 }
        let second = await rig.reopen()
        let hub = MachineHub(space: rig.space)
        await hub.configureV2(second)
        tasks.addTask { try await second.run() }
        let leg = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
        let caller = Task { await endpoint.run(leg) }
        defer { caller.cancel() }
        #expect(try await eventually(5) { events.status != nil })
        #expect(events.status == .exited(code: 1))
        #expect(events.timedOut == .statusUnknown)
        #expect(try await rig.space.execRecord(minted.id)?.terminal == .machineLost)
        rig.side.release()
        await rig.agent.shutdown(); await second.shutdown()
      }
    }
  }

  /// A record the store refuses to write is set aside alone at boot: the group's other execs resume and their callers read
  /// them to the end, and the refused operation keeps no driver.
  @Test func aRecordTheStoreRefusesIsSetAsideAlone() async throws {
    let rig = try await Rig()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["gate", "before", "after"], timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      // A file operation the restart abandons, which writes its record.
      let opener = rig.service()
      let start = StartRequest(kind: "exec.v1", input: ["argv": ["hold", "f"], "cwd": "/tmp", "stdin": false])
      let refused = try await opener.operations(group: .shared).open(.init(scope: "files", key: "refused"), machine: rig.machine.id.rawValue, start: start)
      await opener.shutdown()
      try await rig.serveUntilRestart(minted, endpoint: endpoint) { _ in events.stdout == "before" }

      let space = rig.space, key = rig.key
      let second = await rig.reopen { group in
        RefusingWrites(base: try await space.machineV2Store(group: group, key: key, problemsGroup: MachineV2Service.problemsGroup), refused: refused.id)
      }
      #expect(await second.recovered(.shared))
      let hub = MachineHub(space: rig.space)
      await hub.configureV2(second)
      tasks.addTask { try await second.run() }
      rig.side.release()
      let leg = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
      let caller = Task { await endpoint.run(leg) }
      defer { caller.cancel() }
      _ = await following.value
      #expect(events.stdout == "beforeafter")
      #expect(events.status == .exited(code: 5))
      let operations = try await second.operations(group: .shared)
      #expect(try await eventually { await operations.running == 0 })
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  /// One damaged record fails neither the service nor its group: boot sets it aside, its exec ends with an unknown outcome, and
  /// the group's other exec resumes and finishes.
  @Test func aDamagedRecordIsSetAsideAlone() async throws {
    let rig = try await Rig()
    let healthy = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let damaged = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: healthy.id, cwd: "/tmp", command: ["gate", "before", "after"], timeout: 60))
    let events = Events()
    let following = events.follow(outgoing)
    defer { following.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      let opener = rig.service()
      _ = try await rig.openWithoutRelayState(damaged, command: ["hold", "d"], in: opener)
      await opener.shutdown()
      try await rig.serveUntilRestart(healthy, endpoint: endpoint) { _ in events.stdout == "before" }
      try await rig.space.writer.write { db in
        try db.execute(sql: "UPDATE machine_v2_operations SET record = 'damaged' WHERE invocation_key = '\(damaged.id.rawValue)'")
      }

      let second = await rig.reopen()
      #expect(await second.recovered(.shared))
      #expect(try await rig.space.execRecord(damaged.id)?.terminal == .machineLost)
      let hub = MachineHub(space: rig.space)
      await hub.configureV2(second)
      tasks.addTask { try await second.run() }
      rig.side.release()
      let leg = try await connectExecCaller(healthy.id, space: rig.space, hub: hub)
      let caller = Task { await endpoint.run(leg) }
      defer { caller.cancel() }
      _ = await following.value
      #expect(events.stdout == "beforeafter")
      #expect(events.status == .exited(code: 5))
      await rig.agent.shutdown(); await second.shutdown()
    }
  }

  /// The rollout boundary: an exec a server from before this release started has no relay state to resume from. Boot ends it
  /// on the machine and records its outcome as unknown, and its caller, coming back, is told so by the exec's record instead
  /// of reaching an endpoint.
  @Test func anExecFromBeforeTheUpgradeEndsWithAnUnknownOutcome() async throws {
    let rig = try await Rig()
    let minted = try await rig.space.mintExec(machine: rig.machine.id, group: .shared)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await rig.agent.run() }
      defer { tasks.cancelAll() }
      let old = rig.service()
      _ = try await rig.openWithoutRelayState(minted, command: ["hold", "x"], in: old)
      await old.shutdown()

      let second = await rig.reopen()
      #expect(try await rig.space.execRecord(minted.id)?.terminal == .machineLost)
      #expect(try await eventually { rig.side.reasons.withLock { $0 } == [MachineV2Service.serverUpgraded] })
      let hub = MachineHub(space: rig.space)
      await hub.configureV2(second)
      tasks.addTask { try await second.run() }
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["hold", "x"], timeout: 60))
      let events = Events()
      let following = events.follow(outgoing)
      defer { following.cancel() }
      let leg = try await connectExecCaller(minted.id, space: rig.space, hub: hub)
      // The connection ends with nothing on it: the caller reads how the exec ended from its record.
      await endpoint.run(leg)
      #expect(events.log.withLock { $0 }.isEmpty)
      await rig.agent.shutdown(); await second.shutdown()
    }
  }
}

private final class HeldConsumption: OperationStore, Sendable {
  let base: any OperationStore
  let saving = Gate()
  let saved = Gate()
  let release = Gate()
  let discarded = Gate()
  let operation = Mutex<UUID?>(nil)
  init(base: any OperationStore) { self.base = base }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] { try await base.live() }
  func setAside(_ id: UUID) async throws { try await base.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OperationClient.OutputChunk?) async throws {
    try await base.save(record, appending: chunk)
    if record.discard {
      #expect(record.consumed["stdout"]?.rawValue == 3)
      operation.withLock { $0 = record.id }
      saving.open()
      discarded.open()
    }
  }

  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws {
    if !record.discard, record.consumed["stdout"]?.rawValue == 3 {
      operation.withLock { $0 = record.id }
      saving.open()
      await release.wait()
      try Task.checkCancellation()
    }
    if record.discard { #expect(record.consumed["stdout"]?.rawValue == 3) }
    try await base.trim(record, removing: sequences)
    if !record.discard, record.consumed["stdout"]?.rawValue == 3 { saved.open() }
    if record.discard {
      #expect(record.consumed["stdout"]?.rawValue == 3)
      operation.withLock { $0 = record.id }
      saving.open()
      discarded.open()
    }
  }
}
