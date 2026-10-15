#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
@testable import ExecSupervisor
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import Testing

/// Retirement against real supervisor processes: the `wuhu` executable answers `machine-v2 supervise`.
@Suite(.timeLimit(.minutes(2))) struct RetireTests {
  func executable() throws -> String {
    let cli = try #require(ProcessInfo.processInfo.environment["WUHU_CLI"])
    return cli.hasPrefix("/") ? cli : FileManager.default.currentDirectoryPath + "/" + cli
  }

  func compose<R: Sendable>(_ home: MachineHome, forgets: Bool = true, _ body: @escaping @Sendable (ComputerAgent, ExecSupervisorRegistry) async throws -> R) async throws -> R {
    try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: home.operations, executable: try executable(), files: .local, kinds: [], forgetsRevokedMachine: forgets, body)
  }

  func start(_ agent: ComputerAgent, _ argv: [String]) async throws -> UUID {
    let id = UUID()
    let request = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": .array(argv.map { .string($0) }), "cwd": "/tmp", "stdin": false])))
    let response = try await agent.handler(request)
    #expect(response.status.code == 201)
    return id
  }

  func verdict(_ agent: ComputerAgent, _ id: UUID) async throws -> OperationSnapshot {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
    while true {
      let snapshot = try await agent.handler(execRequest(id)).body.json(OperationSnapshot.self)
      if snapshot.verdict != nil { return snapshot }
      guard clock.now < deadline else { throw TestFailure.timeout }
      try await clock.sleep(for: .milliseconds(20))
    }
  }

  /// The busy exec writes its own PID, then becomes `sleep`.
  func busy(_ agent: ComputerAgent, _ home: MachineHome) async throws -> (UUID, Int32) {
    let file = home.path + "/busy-" + UUID().uuidString
    let id = try await start(agent, ["/bin/sh", "-c", "echo $$ > \(file).tmp && mv \(file).tmp \(file) && exec sleep 60"])
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
    while true {
      if let text = try? String(contentsOfFile: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return (id, pid) }
      guard clock.now < deadline else { throw TestFailure.timeout }
      try await clock.sleep(for: .milliseconds(20))
    }
  }

  func operationDirectories(_ home: MachineHome) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: home.operations)) ?? []).filter { UUID(uuidString: $0) != nil }
  }

  /// Supervisors are the agent's children: reaped by it already (ECHILD), or reaped here.
  func expectExited(_ supervisors: Set<Int32>) async throws {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
    var running = supervisors
    while !running.isEmpty, clock.now < deadline {
      running = running.filter { pid in
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        return reaped == 0
      }
      if !running.isEmpty { try await clock.sleep(for: .milliseconds(20)) }
    }
    #expect(running.isEmpty, "supervisors still running: \(running)")
  }

  func expectGone(_ pid: Int32) async throws {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
    while kill(pid, 0) == 0, clock.now < deadline { try await clock.sleep(for: .milliseconds(20)) }
    #expect(kill(pid, 0) != 0 && errno == ESRCH, "the busy exec \(pid) outlived its retired supervisor")
  }

  func retire(_ outcome: SupervisorRetirement, _ home: MachineHome, forgets: Bool = true) async throws -> (supervisors: Set<Int32>, child: Int32) {
    try await compose(home, forgets: forgets) { agent, registry in
      let idle = try await start(agent, ["/bin/sh", "-c", "exit 0"])
      let ended = try await verdict(agent, idle)
      #expect(ended.verdict?.tag == .completed, "\(ended)")
      let (busy, child) = try await busy(agent, home)
      let supervisors = await registry.childPIDs
      #expect(supervisors.count == 2, "both supervisors are alive: one holds a receipt, one runs an exec")
      #expect(Set(operationDirectories(home)) == [idle.uuidString, busy.uuidString])
      let clock = ContinuousClock(); let began = clock.now
      let remaining = await registry.retire(outcome)
      #expect(clock.now - began < ExecSupervisorRegistry.retireDeadline)
      #expect(remaining.isEmpty)
      #expect(operationDirectories(home).isEmpty, "each supervisor removed its own directory on its way out")
      let refused = try await agent.handler(execRequest(UUID(), method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "exit 0"], "cwd": "/tmp", "stdin": false]))))
      #expect(try await refused.body.json(ErrorEnvelope.self).error.code == .leaving, "a retired agent starts nothing")
      return (supervisors, child)
    }
  }

  @Test func revokeRetiresIdleAndBusySupervisorsAndRemovesTheMachineDirectory() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let (supervisors, child) = try await retire(.revoked, home)
    try await expectExited(supervisors)
    try await expectGone(child)
    var state = stat()
    #expect(lstat(home.path, &state) != 0 && errno == ENOENT, "the revoked machine's directory is gone once the agent stops")
  }

  /// The installed agent's home holds its key, configuration and executable; uninstalling it removes them.
  @Test func aRevokedInstalledAgentRetiresItsSupervisorsAndKeepsItsHome() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let (supervisors, child) = try await retire(.revoked, home, forgets: false)
    try await expectExited(supervisors)
    try await expectGone(child)
    var state = stat()
    #expect(lstat(home.operations, &state) == 0 && state.st_mode & S_IFMT == S_IFDIR)
    #expect(operationDirectories(home).isEmpty)
  }

  @Test func turnOffRetiresIdleAndBusySupervisorsAndKeepsTheMachineDirectory() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let (supervisors, child) = try await retire(.turnedOff, home)
    try await expectExited(supervisors)
    try await expectGone(child)
    var state = stat()
    #expect(lstat(home.operations, &state) == 0 && state.st_mode & S_IFMT == S_IFDIR, "a turned-off machine keeps its directory")
    // Turning the machine back on resumes in the same directory.
    try await compose(home) { agent, _ in
      let id = try await start(agent, ["/bin/sh", "-c", "exit 4"])
      #expect(try await verdict(agent, id).verdict?.result == ["termination": ["tag": "exit", "code": 4]])
    }
  }

  @Test func aRetireWithoutTheSupervisorsNonceIsRefusedAndTheExecKeepsRunning() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let (supervisors, child) = try await compose(home) { agent, registry in
      let (busy, child) = try await busy(agent, home)
      try await waitForLink(registry, busy)
      let link = try #require(await registry.links[busy]?.client)
      for nonce in [nil, "0" + String(repeating: "f", count: 71)] {
        var request = Request(url: URL(string: "http://localhost/retire")!, method: .put)
        request.headers["Host"] = "localhost"
        if let nonce { request.headers["X-Wuhu-Supervisor-Nonce"] = nonce }
        let response = try await link(request)
        #expect(response.status.code == 403)
        #expect(try await response.body.json(ErrorEnvelope.self).error.code == .machineNotAuthorized)
      }
      try await ContinuousClock().sleep(for: .milliseconds(300))
      #expect(try await agent.handler(execRequest(busy)).body.json(OperationSnapshot.self).verdict == nil, "the exec still runs")
      #expect(kill(child, 0) == 0)
      #expect(operationDirectories(home) == [busy.uuidString])
      let supervisors = await registry.childPIDs
      #expect(await registry.retire(.revoked).isEmpty)
      return (supervisors, child)
    }
    try await expectExited(supervisors)
    try await expectGone(child)
  }

  /// A supervisor that never answers (here: none runs for a recovered manifest) holds retirement only to the bound and is not signalled.
  @Test func anUnansweredSupervisorIsLeftToItsLeaseAndRetirementIsBounded() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    try await compose(home) { _, registry in
      let clock = ContinuousClock(); let began = clock.now
      let remaining = await registry.retire(.turnedOff, deadline: .seconds(1))
      #expect(clock.now - began < .seconds(4))
      #expect(remaining == [manifest.operation])
      #expect(operationDirectories(home) == [manifest.operation.uuidString], "the agent never removes a supervisor's directory itself")
    }
  }
}
