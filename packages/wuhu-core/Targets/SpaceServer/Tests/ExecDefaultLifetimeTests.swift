import Crypto
import Dependencies
@testable import ExecSupervisor
import Fetch
import Foundation
import JSONValue
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
    let agent = makeAgent(state: state)
    let dialer = AgentDialer()
    let session = try await makeLifetimeSession(space)
    try await withThrowingTaskGroup(of: Void.self) { lifetime in
      lifetime.addTask { await agent.run(dial: dialer.dial) }
      lifetime.addTask { await server.run() }
      defer { lifetime.cancelAll() }
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      let executor = ToolExecutor(space: space, machines: machineSeam(hub: server.hub), exec: execBackend(space: space, hub: server.hub))
      // The v1 agent stops reading output when it kills, and says so.
      try await expectLifetimes(executor, session: session, machine: machine.rawValue, cwd: work.path, cut: "\n[output was cut when the command stopped]")
    }
  }

  @Test func theV2SupervisorKillsTheProcessGroupAtTheDefaultLifetime() async throws {
    let work = try ScratchFolder("exec-default-lifetime-v2")
    defer { work.remove() }
    let space = try makeMachineSpace()
    let (record, _) = try await space.addMachineV2(name: "lifetime-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let coordinator = MachineV2Coordinator(space: space, key: SymmetricKey(size: .bits256), problemsGroup: .shared, origin: URL(string: "https://test.invalid")!, fetch: { _ in FetchClient { try await agent.handler($0) } }, abort: { _, _ in })
    try await coordinator.prepare()
    let service = MachineV2Service(hub: MachineV2Hub(space: space), coordinator: coordinator, failure: nil)
    await hub.configureV2(service)
    let session = try await makeLifetimeSession(space)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let executor = ToolExecutor(space: space, machines: machineSeam(hub: hub), exec: execBackend(space: space, hub: hub))
      try await expectLifetimes(executor, session: session, machine: record.id.rawValue, cwd: work.path, cut: "")
      await agent.shutdown(); await service.shutdown()
    }
  }

  /// A timeout stop that never ends the process, never answers or fails must
  /// not hold the caller: one grace after the lifetime the exec fails as a
  /// deadline, not as an exit the process never made.
  @Test(arguments: [StuckStop.ignored, .unanswered, .failed])
  func aV2TimeoutStopThatNeverEndsTheProcessIsARequestDeadline(_ stop: StuckStop) async throws {
    let space = try makeMachineSpace()
    let (record, _) = try await space.addMachineV2(name: "stuck-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(DeafExecKind())], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let stopped = Mutex<ContinuousClock.Instant?>(nil)
    let fetch = FetchClient { request in
      if request.url.lastPathComponent == "stop" { stopped.withLock { $0 = $0 ?? .now } }
      if request.url.lastPathComponent == "stop", stop != .ignored {
        if stop == .unanswered { try await ContinuousClock().sleep(for: .seconds(3600)) }
        throw StopRefused()
      }
      return try await agent.handler(request)
    }
    let coordinator = MachineV2Coordinator(space: space, key: SymmetricKey(size: .bits256), problemsGroup: .shared, origin: URL(string: "https://test.invalid")!, fetch: { _ in fetch }, abort: { _, _ in })
    try await coordinator.prepare()
    let service = MachineV2Service(hub: MachineV2Hub(space: space), coordinator: coordinator, failure: nil)
    await hub.configureV2(service)
    let session = try await makeLifetimeSession(space)
    try await MachineV2Service.$timeoutStopGrace.withValue(.seconds(1)) {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await agent.run() }
        tasks.addTask { try await service.run() }
        defer { tasks.cancelAll() }
        let executor = ToolExecutor(space: space, machines: machineSeam(hub: hub), exec: execBackend(space: space, hub: hub))
        let outcome = try await withDependencies {
          $0.date = DateGenerator { Date() }
          $0.continuousClock = ContinuousClock()
        } operation: {
          try await executor.execute(session: session, call: ToolCall(id: "stuck", name: "exec", arguments: .object([
            "machine": .string(record.id.rawValue), "cwd": "/", "command": "true", "max_lifetime_seconds": 1,
          ])), state: ToolExecutionState())
        }
        let answered = ContinuousClock.now
        guard case let .failure(failure) = outcome else {
          Issue.record("a stuck timeout returned \(outcome)")
          return
        }
        #expect(failure.code == "requestDeadline", "\(failure.message)")
        // Within the grace after the stop, well short of a stop request's own five-second deadline on top. Under
        // load the stop can reach the machine only after the caller was answered, which held it even less; the
        // lifetime's own start is not visible here, and a wall clock from the call would measure the setup too.
        if let stopped = stopped.withLock({ $0 }) {
          #expect(stopped.duration(to: answered) < .seconds(3), "answered \(stopped.duration(to: answered)) after the stop")
        }
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
    try await Task.sleep(for: .seconds(3600))
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
private func expectLifetimes(_ executor: ToolExecutor, session: SessionID, machine: String, cwd: String, cut: String) async throws {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
  } operation: {
    try await ToolLifetimes.$execDefault.withValue(1) {
      let killed = try await executor.execute(session: session, call: ToolCall(id: "default-lifetime", name: "exec", arguments: .object([
        "machine": .string(machine), "cwd": .string(cwd),
        "command": "sleep 60 & echo $! > child; echo started; wait",
      ])), state: ToolExecutionState())
      guard case let .exec(result) = killed else {
        Issue.record("default-lifetime exec failed: \(killed)")
        return
      }
      #expect(result.output == "started\n" + cut + "\n[killed after 1 s, the default max lifetime; start longer work detached and watch it from run_script]")
      #expect(result.exitCode == 128 + 15, "\(result.output)")
      let child = try #require(Int32(String(contentsOfFile: cwd + "/child", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
      #expect(try await realPollUntil { !isRunning(child) }, "the backgrounded child survived the kill")

      let explicit = try await executor.execute(session: session, call: ToolCall(id: "explicit-lifetime", name: "exec", arguments: .object([
        "machine": .string(machine), "cwd": .string(cwd),
        "command": "sleep 2; echo finished", "max_lifetime_seconds": 30,
      ])), state: ToolExecutionState())
      guard case let .exec(finished) = explicit else {
        Issue.record("explicit-lifetime exec failed: \(explicit)")
        return
      }
      #expect(finished.output == "finished\n")
      #expect(finished.exitCode == 0)
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
