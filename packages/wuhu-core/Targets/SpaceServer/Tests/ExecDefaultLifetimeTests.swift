import ClockTesting
import Crypto
import Dependencies
@testable import ExecSupervisor
import Fetch
import Foundation
import JSONValue
import MachineAgent
import MachineChannel
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import struct WuhuAI.ToolCall

@Suite(.timeLimit(.minutes(1)))
struct ExecDefaultLifetimeTests {
  @Test func theV1AgentKillsTheProcessGroupAtTheDefaultLifetime() async throws {
    let state = try ScratchFolder("exec-default-lifetime-agent")
    let work = try ScratchFolder("exec-default-lifetime-work")
    defer { state.remove(); work.remove() }
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let clock = LifetimeClock()
    let agent = withDependencies { $0.continuousClock = clock } operation: {
      MachineAgent(stateDirectory: state.path, killGrace: .milliseconds(300))
    }
    let dialer = AgentDialer()
    let session = try await makeLifetimeSession(space)
    try await withThrowingTaskGroup(of: Void.self) { lifetime in
      lifetime.addTask { await agent.run(dial: dialer.dial) }
      lifetime.addTask { await server.run() }
      defer { lifetime.cancelAll() }
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      let ready = LifetimeOutput()
      let executor = ToolExecutor(space: space, machines: machineSeam(hub: server.hub), exec: observingOutput(execBackend(space: space, hub: server.hub), ready: ready))
      // The v1 agent stops reading output when it kills, and says so.
      try await expectLifetimes(executor, session: session, machine: machine.rawValue, cwd: work.path, cut: "\n[output was cut when the command stopped]", clock: clock, ready: ready)
    }
  }

  @Test func theV2SupervisorKillsTheProcessGroupAtTheDefaultLifetime() async throws {
    let clock = LifetimeClock()
    let work = try ScratchFolder("exec-default-lifetime-v2")
    defer { work.remove() }
    let space = try makeMachineSpace()
    let (record, _) = try await space.addMachineV2(name: "lifetime-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { try await agent.handler($0) } })
    await hub.configureV2(service)
    let session = try await makeLifetimeSession(space)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await withDependencies { $0.continuousClock = clock } operation: { try await service.run() } }
      defer { tasks.cancelAll() }
      let ready = LifetimeOutput()
      let executor = ToolExecutor(space: space, machines: machineSeam(hub: hub), exec: observingOutput(execBackend(space: space, hub: hub), ready: ready))
      try await expectLifetimes(executor, session: session, machine: record.id.rawValue, cwd: work.path, cut: "", clock: clock, ready: ready)
      await agent.shutdown(); await service.shutdown()
    }
  }

  /// A timeout stop that never ends the process, never answers or fails must
  /// not hold the caller: one grace after the lifetime the exec fails as a
  /// deadline, not as an exit the process never made. The relay runs on a
  /// `VirtualClock`: it stops at the lifetime until the stop reaches the
  /// machine, then never passes the grace after it, so a relay that held the
  /// caller longer would never answer.
  @Test(arguments: [StuckStop.ignored, .unanswered, .failed])
  func aV2TimeoutStopThatNeverEndsTheProcessIsARequestDeadline(_ stop: StuckStop) async throws {
    let clock = VirtualClock()
    let lifetime = 20
    let space = try makeMachineSpace()
    let (record, _) = try await space.addMachineV2(name: "stuck-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(DeafExecKind())], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let started = Gate()
    let stopped = Gate()
    let fetch = FetchClient { request in
      if request.method == .post, request.url.path.contains("/operations/") { started.open() }
      if request.url.lastPathComponent == "stop" { stopped.open() }
      if request.url.lastPathComponent == "stop", stop != .ignored {
        if stop == .unanswered { await Gate().wait(); try Task.checkCancellation() }
        throw StopRefused()
      }
      return try await agent.handler(request)
    }
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in fetch })
    await hub.configureV2(service)
    let session = try await makeLifetimeSession(space)
    try await MachineV2Service.$timeoutStopGrace.withValue(.seconds(20)) {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await agent.run() }
        tasks.addTask { try await withDependencies { $0.continuousClock = clock } operation: { try await service.run() } }
        defer { tasks.cancelAll() }
        let executor = ToolExecutor(space: space, machines: machineSeam(hub: hub), exec: execBackend(space: space, hub: hub))
        let outcome = try await withThrowingTaskGroup(of: ToolResultPayload.self) { call in
          call.addTask {
            try await withDependencies {
              $0.date = DateGenerator { Date() }
              $0.continuousClock = ContinuousClock()
            } operation: {
              try await executor.execute(session: session, call: ToolCall(id: "stuck", name: "exec", arguments: .object([
                "machine": .string(record.id.rawValue), "cwd": "/", "command": "true", "max_lifetime_seconds": .integer(lifetime),
              ])), state: ToolExecutionState())
            }
          }
          // The clock stands still until the start reaches the machine, after the exec was admitted with its deadline.
          await started.wait()
          try await clock.run(through: VirtualClock.at(.seconds(lifetime))) { await stopped.wait() }
          return try await clock.run(through: VirtualClock.at(.seconds(lifetime) + MachineV2Service.timeoutStopGrace)) { try await call.next()! }
        }
        guard case let .failure(failure) = outcome else {
          Issue.record("a stuck timeout returned \(outcome)")
          return
        }
        #expect(failure.code == "requestDeadline", "\(failure.message)")
        await service.shutdown()
      }
    }
  }
}

enum StuckStop: Sendable, CustomTestStringConvertible {
  case ignored, unanswered, failed
  var testDescription: String { "\(self)" }
}

private struct StopRefused: Error {}

/// An exec kind whose process never ends: it prints once and ignores stop.
private struct DeafExecKind: OperationKind {
  struct Input: Decodable, Sendable {}
  let descriptor = ComputerKindSchemas.exec
  func run(_: Input, channels: OperationChannels, cancellation _: OperationCancellation) async throws -> JSONValue {
    try await channels.send(.init(data: Data("started\n".utf8)), to: "stdout")
    await Gate().wait()
    try Task.checkCancellation()
    return .null
  }
}

private func makeLifetimeSession(_ space: Space) async throws -> SessionID {
  try await space.sessions.createSession(
    group: .shared, title: "exec lifetime", kind: .agent, createdBy: "morgan",
    model: .init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high"),
  )
}

// The default is shortened to 1 s: the command and the child it backgrounds
// must both be gone, and an explicit max_lifetime_seconds must outlast the default.
private func expectLifetimes(_ executor: ToolExecutor, session: SessionID, machine: String, cwd: String, cut: String, clock: LifetimeClock, ready: LifetimeOutput) async throws {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
  } operation: {
    try await ToolLifetimes.$execDefault.withValue(1) {
      try await withThrowingTaskGroup(of: ToolResultPayload.self) { call in
        defer { call.cancelAll() }
        call.addTask { try await executor.execute(session: session, call: ToolCall(id: "default-lifetime", name: "exec", arguments: .object([
          "machine": .string(machine), "cwd": .string(cwd),
          "command": "mkfifo child-input; trap 'wait; exit 143' TERM; cat child-input & echo $! > child; echo started; wait",
        ])), state: ToolExecutionState()) }
        await ready.first.wait()
        await clock.armed.wait()
        let killed = try await clock.run(through: VirtualClock.at(.seconds(1) + .milliseconds(300))) { try await call.next()! }
        guard case let .exec(result) = killed else {
          Issue.record("default-lifetime exec failed: \(killed)")
          return
        }
        #expect(result.output == "started\n" + cut + "\n[killed after 1 s, the default max lifetime; start longer work detached and watch it from run_script]")
        #expect([128 + 15, 128 + 9].contains(result.exitCode), "\(result.output)")
        let child = try #require(Int32(String(contentsOfFile: cwd + "/child", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!isRunning(child), "the backgrounded child survived the kill")

        call.addTask { try await executor.execute(session: session, call: ToolCall(id: "explicit-lifetime", name: "exec", arguments: .object([
          "machine": .string(machine), "cwd": .string(cwd),
          "command": "mkfifo release; exec 3<>release; echo ready; read line <&3; echo finished", "max_lifetime_seconds": 30,
        ])), state: ToolExecutionState()) }
        await ready.second.wait()
        let pastDefault = clock.now.advanced(by: .seconds(2))
        try await clock.run(through: pastDefault) { try await clock.sleep(until: pastDefault, tolerance: nil) }
        let fd = open(cwd + "/release", O_WRONLY | O_NONBLOCK)
        try #require(fd >= 0, "the explicit lifetime ended before its release")
        let release = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try release.write(contentsOf: Data("go\n".utf8))
        try release.close()
        let explicit = try await call.next()!
        guard case let .exec(finished) = explicit else {
          Issue.record("explicit-lifetime exec failed: \(explicit)")
          return
        }
        #expect(finished.output == "ready\nfinished\n")
        #expect(ready.timeouts.withLock { $0.values.sorted() } == [1, 30])
        #expect(finished.exitCode == 0)
      }
    }
  }
}

private func isRunning(_ pid: Int32) -> Bool {
  guard kill(pid, 0) == 0 else { return false }
  #if os(Linux)
    // An orphan nobody has reaped yet still answers kill(0).
    if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let name = stat.lastIndex(of: ")") {
      return !stat[name...].hasPrefix(") Z")
    }
  #endif
  return true
}

private final class LifetimeClock: Clock, Sendable {
  typealias Instant = VirtualClock.Instant
  let base = VirtualClock()
  let armed = Gate()
  var now: Instant { base.now }
  var minimumResolution: Duration { base.minimumResolution }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    if now.duration(to: deadline) == .seconds(1) { armed.open() }
    try await base.sleep(until: deadline, tolerance: tolerance)
  }

  func run<T>(through limit: Instant, _ body: () async throws -> T) async throws -> T {
    try await base.run(through: limit, body)
  }
}

private final class LifetimeOutput: Sendable {
  let first = Gate()
  let second = Gate()
  let timeouts = Mutex<[ExecID: Double]>([:])
  let connections = Mutex(0)
}

private func observingOutput(_ backend: ExecBackend, ready: LifetimeOutput) -> ExecBackend {
  var observed = backend
  observed.connect = { id in
    let index = ready.connections.withLock { value in defer { value += 1 }; return value }
    return LifetimeTransport(base: try await backend.connect(id), ready: ready, output: index == 0 ? ready.first : ready.second)
  }
  return observed
}

private struct LifetimeTransport: FrameTransport {
  let base: any FrameTransport
  let ready: LifetimeOutput
  let inbound: AsyncStream<[UInt8]>
  init(base: any FrameTransport, ready: LifetimeOutput, output: Gate) {
    self.base = base
    self.ready = ready
    inbound = AsyncStream { continuation in
      let task = Task {
        for await bytes in base.inbound {
          continuation.yield(bytes)
          if (try? FrameCodec.decode(bytes))?.opcode == .output { output.open() }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func send(_ bytes: [UInt8]) async throws {
    if let frame = try? FrameCodec.decode(bytes), frame.opcode == .execStart,
       let start = try? frame.payload(ExecStart.self), let timeout = start.timeout
    {
      ready.timeouts.withLock { $0[start.id] = timeout }
    }
    try await base.send(bytes)
  }

  func close() { base.close() }
}
