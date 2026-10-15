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
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import Synchronization
import Testing

/// Retirement against real supervisor processes: the `wuhu` executable answers `machine-v2 supervise`.
@Suite(.timeLimit(.minutes(2))) struct RetireTests {
  func executable() throws -> String {
    let cli = try #require(ProcessInfo.processInfo.environment["WUHU_CLI"])
    return cli.hasPrefix("/") ? cli : FileManager.default.currentDirectoryPath + "/" + cli
  }

  /// Every supervisor the body started is gone when it returns or throws: supervisors outlive their agent by design.
  func compose<R: Sendable>(_ home: MachineHome, forgets: Bool = true, _ body: @escaping @Sendable (ComputerAgent, ExecSupervisorRegistry) async throws -> R) async throws -> R {
    try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: home.operations, executable: try executable(), files: .local, kinds: [], forgetsRevokedMachine: forgets) { agent, registry in
      let value: R
      do { value = try await body(agent, registry) } catch {
        await tearDown(registry, failed: true)
        throw error
      }
      await tearDown(registry, failed: false)
      return value
    }
  }

  /// A body that threw is retired here; whatever still runs afterwards is killed with its execs. A body that returned
  /// normally must have retired its supervisors itself, so one still running fails the test.
  func tearDown(_ registry: ExecSupervisorRegistry, failed: Bool) async {
    if failed, !(await registry.childPIDs).isEmpty { _ = await registry.retire(.turnedOff, deadline: .seconds(3)) }
    var running = await registry.childPIDs
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
    while true {
      running = running.filter { pid in
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == 0
      }
      guard !running.isEmpty, clock.now < deadline else { break }
      try? await clock.sleep(for: .milliseconds(20))
    }
    guard !running.isEmpty else { return }
    if !failed { Issue.record("supervisors outlived the test: \(running)") }
    killWithDescendants(running)
  }

  /// A supervisor kills and reaps its exec's process group on its way out, which a SIGKILL skips; so its descendants
  /// and the process groups they lead are killed here too. The supervisors are frozen first so the tree holds still.
  func killWithDescendants(_ supervisors: Set<Int32>) {
    for pid in supervisors { kill(pid, SIGSTOP) }
    let table = processTable()
    var tree = supervisors
    var grew = true
    while grew {
      grew = false
      for entry in table where tree.contains(entry.ppid) && !tree.contains(entry.pid) {
        tree.insert(entry.pid)
        grew = true
      }
    }
    let own = getpgrp()
    for entry in table where tree.contains(entry.pid) && entry.pid == entry.pgid && entry.pgid != own { killpg(entry.pgid, SIGKILL) }
    for pid in tree { kill(pid, SIGKILL) }
    for pid in supervisors {
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }
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
    while alive(pid), clock.now < deadline { try await clock.sleep(for: .milliseconds(20)) }
    #expect(!alive(pid), "the busy exec \(pid) outlived its retired supervisor")
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
    let resumed = try await compose(home) { agent, registry in
      let id = try await start(agent, ["/bin/sh", "-c", "exit 4"])
      #expect(try await verdict(agent, id).verdict?.result == ["termination": ["tag": "exit", "code": 4]])
      // Its supervisor holds the receipt until retired; left alone it would outlive the test.
      let supervisors = await registry.childPIDs
      #expect(supervisors.count == 1)
      #expect(await registry.retire(.turnedOff).isEmpty)
      return supervisors
    }
    try await expectExited(resumed)
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

  /// The hard fallback: a supervisor that neither answers nor exits (here: stopped) when a test fails is killed, and so
  /// is the exec it would have killed on its way out.
  @Test func aFailingTestKillsAStoppedSupervisorAndItsExec() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let started = Mutex<(supervisors: Set<Int32>, child: Int32)>(([], 0))
    await #expect(throws: Abandoned.self) {
      try await compose(home) { agent, registry in
        let (busy, child) = try await busy(agent, home)
        try await waitForLink(registry, busy)
        let supervisors = await registry.childPIDs
        started.withLock { $0 = (supervisors, child) }
        for pid in supervisors { kill(pid, SIGSTOP) }
        throw Abandoned()
      }
    }
    let (supervisors, child) = started.withLock { $0 }
    #expect(supervisors.count == 1)
    for pid in supervisors { #expect(!alive(pid), "the stopped supervisor \(pid) was killed") }
    try await expectGone(child)
  }
}

struct Abandoned: Error {}

struct ProcessEntry { let pid, ppid, pgid: Int32 }

/// Every process's parent and process group.
func processTable() -> [ProcessEntry] {
  #if os(Linux)
    let pids = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { Int32($0) }
    return pids.compactMap { pid in
      // After the parenthesised command: state, ppid, pgrp.
      guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = stat.lastIndex(of: ")") else { return nil }
      let fields = stat[stat.index(after: close)...].split(separator: " ")
      guard fields.count > 2, let ppid = Int32(fields[1]), let pgid = Int32(fields[2]) else { return nil }
      return ProcessEntry(pid: pid, ppid: ppid, pgid: pgid)
    }
  #else
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-A", "-o", "pid=,ppid=,pgid="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
      let fields = line.split(separator: " ").compactMap { Int32($0) }
      return fields.count == 3 ? ProcessEntry(pid: fields[0], ppid: fields[1], pgid: fields[2]) : nil
    }
  #endif
}

/// Running, not merely unreaped: an orphan's zombie lingers until its new parent reaps it.
func alive(_ pid: Int32) -> Bool {
  guard kill(pid, 0) == 0 else { return false }
  #if os(Linux)
    guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = stat.lastIndex(of: ")") else { return false }
    return !stat[stat.index(after: close)...].hasPrefix(" Z")
  #else
    return true
  #endif
}
