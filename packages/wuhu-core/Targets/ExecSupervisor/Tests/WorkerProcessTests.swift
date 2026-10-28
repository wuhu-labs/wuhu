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
import CExecSupervisor
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.Verdict
import class OperationRuntime.OperationAgent
import Synchronization
import Testing

/// Exec workers as real processes: the `wuhu` executable answers `machine-v2 exec-worker`.
@Suite(.timeLimit(.minutes(3))) struct WorkerProcessTests {
  final class Launched: Sendable {
    let launches = Mutex<[(pid: Int32, directory: String)]>([])
    var all: [Int32] { launches.withLock { $0.map(\.pid) } }
    var directories: [String] { launches.withLock { $0.map(\.directory) } }
  }

  /// Every worker the body launched is gone when it returns or throws, unless `keep`: a worker holding operations outlives its
  /// agent by design. Receipts lapse after `retention`, so a retired worker exits within the test.
  func compose<R: Sendable>(_ home: MachineHome, forgets: Bool = true, retention: Duration = .seconds(1), launched: Launched = Launched(), keep: Bool = false, teardownGrace: Duration = .seconds(5), _ body: @escaping @Sendable (ComputerAgent, ExecWorkers) async throws -> R) async throws -> R {
    try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: home.operations, executable: try machineExecutable(), files: .local, kinds: [], forgetsRevokedMachine: forgets, retention: retention, launch: { arguments in
      let pid = try ExecSupervisor.launchReaped(arguments)
      launched.launches.withLock { $0.append((pid, arguments[3])) }
      return pid
    }) { agent, workers in
      let value: R
      do { value = try await body(agent, workers) } catch {
        await tearDown(workers, launched, failed: true, grace: teardownGrace)
        throw error
      }
      if !keep { await tearDown(workers, launched, failed: false, grace: teardownGrace) }
      return value
    }
  }

  /// A body that threw is retired here; whatever still runs afterwards is killed with its execs. A body that returned
  /// normally must have retired its workers itself, so one still running fails the test.
  func tearDown(_ workers: ExecWorkers, _ launched: Launched, failed: Bool, grace: Duration) async {
    if failed { _ = await workers.retire(.turnedOff, deadline: min(grace, .seconds(3))) }
    var running = Set(launched.all)
    let clock = ContinuousClock(); let deadline = clock.now + grace
    while true {
      running = running.filter { !exited($0) }
      guard !running.isEmpty, clock.now < deadline else { break }
      try? await clock.sleep(for: .milliseconds(20))
    }
    guard !running.isEmpty else { return }
    if !failed { Issue.record("workers outlived the test: \(running)") }
    killWithDescendants(running)
  }

  /// A worker kills and reaps its execs' process groups on its way out, which a SIGKILL skips; so its descendants and the
  /// process groups they lead are killed here too. The workers are frozen first so the tree holds still.
  func killWithDescendants(_ workers: Set<Int32>) {
    for pid in workers { kill(pid, SIGSTOP) }
    let table = processTable()
    var tree = workers
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
  }

  func start(_ agent: ComputerAgent, _ argv: [String]) async throws -> UUID {
    let id = UUID()
    let request = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": .array(argv.map { .string($0) }), "cwd": "/tmp", "stdin": false])))
    _ = try await snapshotOf(agent.handler(request))
    return id
  }

  func verdict(_ agent: ComputerAgent, _ id: UUID) async throws -> OperationSnapshot {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
    while true {
      let snapshot = try await snapshotOf(agent.handler(execRequest(id)))
      if snapshot.verdict != nil { return snapshot }
      guard clock.now < deadline else { throw TestFailure.timeout }
      try await clock.sleep(for: .milliseconds(20))
    }
  }

  /// The snapshot an answer carries; an error answer fails with its code and message.
  func snapshotOf(_ response: Response) async throws -> OperationSnapshot {
    let data = try await response.body.bytes(upTo: 1 << 20)
    guard response.status.code == 200 || response.status.code == 201 else {
      let error = try JSONDecoder().decode(ErrorEnvelope.self, from: data).error
      Issue.record("\(response.status.code) \(error.code) \(error.message)")
      throw error
    }
    return try JSONDecoder().decode(OperationSnapshot.self, from: data)
  }

  /// Reads both channels to their end and acknowledges the terminal on each, as the server does: the operation is released.
  func settle(_ agent: ComputerAgent, _ id: UUID) async throws {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
    var finals: [String: UInt64] = [:]
    for channel in ["stdout", "stderr"] {
      var after: UInt64 = 0
      defer { finals[channel] = after }
      while true {
        guard clock.now < deadline else { throw TestFailure.timeout }
        let snapshot = try await snapshotOf(agent.handler(execRequest(id, query: "?channel=\(channel)&after=\(after)")))
        let through = snapshot.through?.rawValue ?? after
        if snapshot.channelEnd, through == after { break }
        if through == after { try await clock.sleep(for: .milliseconds(20)) }
        after = through
      }
    }
    let token = try #require(try await verdict(agent, id).terminalToken)
    for channel in ["stdout", "stderr"] {
      #expect(try await agent.handler(execRequest(id, query: "?channel=\(channel)&after=\(finals[channel]!)&terminalAck=\(token.uuidString)")).status.code == 200)
    }
  }

  /// Publishes the process-group leader for independent liveness assertions.
  func busy(_ agent: ComputerAgent, _ home: MachineHome, backpressure: Bool = false) async throws -> (UUID, Int32) {
    let file = home.path + "/busy-" + UUID().uuidString
    let work = backpressure ? "while :; do printf '%1024s' x; printf '%1024s' y >&2; done" : "exec sleep 60"
    let id = try await start(agent, ["/bin/sh", "-c", "echo $$ > \(file).tmp && mv \(file).tmp \(file) && " + work])
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
    while true {
      if let text = try? String(contentsOfFile: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return (id, pid) }
      guard clock.now < deadline else { throw TestFailure.timeout }
      try await clock.sleep(for: .milliseconds(20))
    }
  }

  func error(_ agent: ComputerAgent, _ id: UUID) async throws -> OperationError {
    try await agent.handler(execRequest(id)).body.json(ErrorEnvelope.self).error
  }

  func isWorkerLost(_ error: OperationError) -> Bool {
    error.code == .unknownOperation && error.details == ["outcome": "unknown", "reason": .string(UnknownOutcome.workerLost.rawValue)]
  }

  func workerDirectories(_ home: MachineHome) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: home.workers)) ?? []).filter { UUID(uuidString: $0) != nil }
  }

  /// Exited and reaped: a zombie still counts as running. Nothing in the test reaps them.
  func expectExited(_ workers: Set<Int32>) async throws {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
    var running = workers
    while !running.isEmpty, clock.now < deadline {
      running = running.filter { !exited($0) }
      if !running.isEmpty { try await clock.sleep(for: .milliseconds(20)) }
    }
    #expect(running.isEmpty, "workers still running or unreaped: \(running)")
  }

  func expectGone(_ pid: Int32) async throws {
    let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
    while alive(pid), clock.now < deadline { try await clock.sleep(for: .milliseconds(20)) }
    #expect(!alive(pid), "the busy exec \(pid) outlived its retired worker")
  }

  /// Retires a worker holding a finished receipt and a running exec, and ends the agent's scope: nothing of the agent is left
  /// to reap the worker or ask it anything. A revoked machine released both receipts; a turned-off one left them to lapse. Either
  /// way the worker exits under its lifetime rule, and is reaped.
  func retire(_ outcome: SupervisorRetirement, _ home: MachineHome, forgets: Bool = true) async throws -> (child: Int32, held: Set<UUID>) {
    let launched = Launched()
    let (child, held) = try await compose(home, forgets: forgets, launched: launched, keep: true) { agent, workers in
      let idle = try await start(agent, ["/bin/sh", "-c", "exit 0"])
      let ended = try await verdict(agent, idle)
      #expect(ended.verdict?.tag == .completed, "\(ended)")
      let (running, child) = try await busy(agent, home)
      #expect(launched.all.count == 1, "one worker holds both: a receipt and a running exec")
      #expect(home.liveWorkers().count == 1)
      let clock = ContinuousClock(); let began = clock.now
      let remaining = await workers.retire(outcome)
      #expect(clock.now - began < ExecWorkers.retireDeadline)
      #expect(remaining == 0)
      let refused = try await agent.handler(execRequest(UUID(), method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "exit 0"], "cwd": "/tmp", "stdin": false]))))
      #expect(try await refused.body.json(ErrorEnvelope.self).error.code == .leaving, "a retired agent starts nothing")
      return (child, Set([idle, running]))
    }
    try await expectExited(Set(launched.all))
    try await expectGone(child)
    return (child, held)
  }

  @Test func revokeRetiresTheWorkerWithItsIdleAndBusyExecsAndRemovesTheMachineDirectory() async throws {
    let home = try MachineHome(); defer { home.remove() }
    _ = try await retire(.revoked, home)
    var state = stat()
    #expect(lstat(home.path, &state) != 0 && errno == ENOENT, "the revoked machine's directory is gone once the agent stops")
  }

  /// The installed agent's home holds its key, configuration and executable; uninstalling it removes them.
  @Test func aRevokedInstalledAgentRetiresItsWorkerAndKeepsItsHome() async throws {
    let home = try MachineHome(); defer { home.remove() }
    _ = try await retire(.revoked, home, forgets: false)
    var state = stat()
    #expect(lstat(home.operations, &state) == 0 && state.st_mode & S_IFMT == S_IFDIR)
    #expect(workerDirectories(home).isEmpty, "both receipts were released: the worker dropped nothing")
  }

  @Test func turnOffRetiresTheWorkerAndKeepsTheMachineDirectory() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let (_, held) = try await retire(.turnedOff, home)
    var state = stat()
    #expect(lstat(home.operations, &state) == 0 && state.st_mode & S_IFMT == S_IFDIR, "a turned-off machine keeps its directory")
    // Turning the machine back on resumes in the same directory, with the loss evidence.
    let launched = Launched()
    try await compose(home, launched: launched) { agent, workers in
      for id in held { #expect(isWorkerLost(try await error(agent, id))) }
      let id = try await start(agent, ["/bin/sh", "-c", "exit 4"])
      #expect(try await verdict(agent, id).verdict?.result == ["termination": ["tag": "exit", "code": 4]])
      #expect(await workers.retire(.turnedOff) == 0)
    }
    try await expectExited(Set(launched.all))
  }

  /// Many execs, one process: the current worker takes every start.
  @Test func concurrentExecsShareOneWorkerProcess() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let launched = Launched()
    try await compose(home, launched: launched) { agent, workers in
      // Each verdict is read as its exec ends: a receipt lapses `retention` after that.
      let tags = try await withThrowingTaskGroup(of: Verdict.Tag?.self, returning: [Verdict.Tag?].self) { group in
        for code in 0 ..< 8 { group.addTask { try await verdict(agent, start(agent, ["/bin/sh", "-c", "sleep 0.2; exit \(code)"])).verdict?.tag } }
        return try await group.reduce(into: []) { $0.append($1) }
      }
      #expect(tags == Array(repeating: .completed, count: 8))
      #expect(launched.all.count == 1)
      #expect(home.liveWorkers().count == 1)
      #expect(await workers.retire(.turnedOff) == 0)
    }
    try await expectExited(Set(launched.all))
  }

  /// The current worker dies under a running exec: the exec is lost (its lock proves the worker is gone), the agent launches the
  /// next worker, and new execs run on it.
  @Test func aCrashedWorkersExecIsLostAndANewWorkerTakesItsPlace() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let launched = Launched()
    try await compose(home, launched: launched) { agent, workers in
      let (busy, child) = try await busy(agent, home)
      defer { kill(child, SIGKILL) }
      let pid = try #require(launched.all.first)
      let directory = try #require(launched.directories.first)
      try await until("the worker records its exec") { (try? WorkerDirectory.inventory(directory))?.retained.contains(busy) == true }
      kill(pid, SIGKILL)
      try await until("the agent finds the exec lost") { (try? await isWorkerLost(error(agent, busy))) == true }
      let next = try await start(agent, ["/bin/sh", "-c", "exit 5"])
      #expect(try await verdict(agent, next).verdict?.result == ["termination": ["tag": "exit", "code": 5]])
      #expect(launched.all.count == 2)
      #expect(isWorkerLost(try await error(agent, busy)))
      #expect(await workers.retire(.turnedOff) == 0)
    }
    try await expectExited(Set(launched.all))
  }

  /// A restarted agent adopts the worker still holding the last agent's execs and launches its own; once those execs settle the
  /// old worker exits, and the machine is back to its agent and one worker.
  @Test func afterARestartTheMachineReturnsToOneWorker() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let first = Launched()
    let ids = try await compose(home, retention: OperationAgent.receiptRetention, launched: first, keep: true) { agent, _ in
      var ids: [UUID] = []
      for _ in 0 ..< 3 { ids.append(try await start(agent, ["/bin/sh", "-c", "sleep 1; printf done"])) }
      return ids
    }
    let old = try #require(first.all.first)
    #expect(first.all.count == 1)
    #expect(alive(old), "it holds operations, so it outlives its agent")
    let second = Launched()
    try await compose(home, retention: OperationAgent.receiptRetention, launched: second) { agent, workers in
      for id in ids { try await settle(agent, id) }
      try await expectExited([old])
      try await until("only the new worker is left") { home.liveWorkers().count == 1 }
      #expect(second.all.count == 1)
      for id in ids { #expect(try await error(agent, id).details == nil, "released, not lost") }
      #expect(await workers.retire(.turnedOff) == 0)
    }
    try await expectExited(Set(second.all))
  }

  /// A supervisor that never answers (here: none runs for a recovered manifest) holds retirement only to the bound and is not signalled.
  @Test func anUnansweredSupervisorIsLeftToItsLeaseAndRetirementIsBounded() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    try await compose(home) { _, workers in
      let clock = ContinuousClock(); let began = clock.now
      let remaining = await workers.retire(.turnedOff, deadline: .seconds(1))
      #expect(clock.now - began < .seconds(4))
      #expect(remaining == 1)
      let entries = try home.entries(manifest.operation)
      #expect(entries == ["manifest.json"], "the agent never removes a supervisor's directory itself")
    }
  }

  @Test(arguments: [false, true]) func uninstallKillsUnlinkedWorkersAndExecGroupsWithoutAnAgentOrOutputAcknowledgement(crashedWorker: Bool) async throws {
    let home = try MachineHome(); defer { home.remove() }
    let launched = Launched()
    let child = Mutex<Int32>(0)
    defer { killWithDescendants(Set(launched.all)) }
    try await compose(home, retention: .seconds(60), launched: launched, keep: true) { agent, _ in
      let (_, pid) = try await busy(agent, home, backpressure: true)
      child.withLock { $0 = pid }
    }
    if crashedWorker {
      for pid in launched.all { kill(pid, SIGKILL) }
      try await expectExited(Set(launched.all))
    }
    // The agent is gone; the worker cannot rely on a tunnel, control socket or consumer.
    try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
    try await expectExited(Set(launched.all))
    try await expectGone(child.withLock { $0 })
    try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
  }

  @Test func execPublishesItsBirthAnchorBeforeUserCodeAndSurvivesThePublishingWorker() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let launched = Launched()
    defer { killWithDescendants(Set(launched.all)) }
    let evidence = home.path + "/published"
    let child = Mutex<Int32>(0)
    try await compose(home, retention: .seconds(60), launched: launched, keep: true) { agent, _ in
      // Not `cat`: its copy_file_range clones the fresh receipt on ZFS, which waits for the block's transaction group to sync.
      _ = try await start(agent, ["/bin/sh", "-c", "IFS= read -r anchor <&3; printf %s \"$anchor\" > \(evidence).tmp && mv \(evidence).tmp \(evidence); exec sleep 60"])
      let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
      while access(evidence, F_OK) != 0 {
        guard clock.now < deadline else { throw TestFailure.timeout }
        try await clock.sleep(for: .milliseconds(10))
      }
      let fields = try String(contentsOfFile: evidence, encoding: .utf8).split(separator: " ")
      try #require(fields.count == 2)
      let pid = try #require(Int32(fields[0]))
      let birth = try #require(UInt64(fields[1]))
      var actual: UInt64 = 0
      #expect(exec_process_birth(pid, &actual) == 0)
      #expect(actual == birth)
      child.withLock { $0 = pid }
    }
    for pid in launched.all { kill(pid, SIGKILL) }
    try await expectExited(Set(launched.all))
    try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
    try await expectGone(child.withLock { $0 })
  }

  @Test func receiptTrampolinePreservesExecFailuresInsteadOfInventingExit127() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await compose(home) { agent, workers in
      let id = try await start(agent, ["/no/such/executable"])
      let snapshot = try await verdict(agent, id)
      #expect(snapshot.verdict?.tag == .failed)
      #expect(snapshot.verdict?.error?.code == .spawnFailed)
      try await settle(agent, id)
      _ = await workers.retire(.revoked)
    }
  }

  /// The hard fallback: a worker that neither answers nor exits (here: stopped) when a test fails is killed, and so is the exec it
  /// would have killed on its way out.
  @Test func aFailingTestKillsAStoppedWorkerAndItsExec() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let launched = Launched()
    let child = Mutex<Int32>(0)
    await #expect(throws: Abandoned.self) {
      // A stopped worker answers nothing in any grace, so a short one only skips the wait.
      try await compose(home, launched: launched, teardownGrace: .milliseconds(200)) { agent, _ in
        let (_, pid) = try await busy(agent, home)
        child.withLock { $0 = pid }
        for worker in launched.all { kill(worker, SIGSTOP) }
        throw Abandoned()
      }
    }
    #expect(launched.all.count == 1)
    try await expectExited(Set(launched.all))
    try await expectGone(child.withLock { $0 })
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

/// Gone and reaped.
func exited(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

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
