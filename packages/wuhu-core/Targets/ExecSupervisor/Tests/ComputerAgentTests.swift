#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import CExecSupervisor
@testable import ComputerFiles
@testable import ExecSupervisor
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import struct OperationRuntime.AnyOperationKind
import struct OperationRuntime.OperationCancellation
import struct OperationRuntime.OperationChannels
import protocol OperationRuntime.OperationKind
import Synchronization
import Testing

@Suite struct ComputerAgentTests {
  func fixture(clock: OperationClock = .continuous) throws -> (ComputerAgent, ExecWorkers) {
    let workers = try ExecWorkers(machine: "test", operationsDirectory: "/tmp/ops", executable: "/tmp/wuhu", launch: { _ in nil }, authorize: { _, _ in })
    return (try ComputerAgent(machine: "test", external: workers.external, clock: clock), workers)
  }

  func describe() -> Request { Request(url: URL(string: "https://agent/machine/v2/machines/test")!) }

  @Test func combinesKindsAndRejectsOtherMachineBeforeDispatch() async throws {
    let (agent, _) = try fixture()
    let description = try await agent.handler(describe()).body.json(MachineDescription.self)
    #expect(Set(description.kinds.map(\.name)) == ["exec.v1", "read.v1", "search.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1"])
    #expect(description.acceptingStarts)
    let response = try await agent.handler(Request(url: URL(string: "https://agent/machine/v2/machines/not-authorized")!))
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .machineNotAuthorized)
  }

  @Test func fileAndExecShareOperationIDsWithNoActiveCap() async throws {
    let (agent, _) = try fixture()
    let fileIDs = (0 ..< 48).map { _ in UUID() }
    for fileID in fileIDs {
      let request = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + fileID.uuidString)!, method: .post, body: try .json(StartRequest(kind: "read.v1", input: ["path": "/tmp/not-opened-before-run"])))
      #expect(try await agent.handler(request).status.code == 201)
    }
    let duplicate = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + fileIDs[0].uuidString)!, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false])))
    #expect(try await agent.handler(duplicate).body.json(ErrorEnvelope.self).error.code == .operationExists)
    await agent.shutdown()
  }

  @Test func uninstallRemovesStaleReceiptsWithoutSignallingTheirPIDs() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let directory = home.operations + "/" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let path = directory + "/.lock"
    try WorkerDirectory.writeFile(path, Data(String(getpgrp()).utf8))
    try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
    #expect(access(path, F_OK) != 0)
    try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
  }

  @Test func uninstallCannotFreezeOrRemoveReceiptsBeforeSpawnPublicationFinishes() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let directory = home.operations + "/" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let receipt = directory + "/.lock"
    try WorkerDirectory.writeFile(receipt, Data(String(getpgrp()).utf8))
    let publishing = exec_lock_file(directory + "/.spawn.lock", 1)
    try #require(publishing >= 0)
    defer { exec_close(publishing) }
    let now = Mutex(Duration.zero)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { duration in now.withLock { $0 += duration } })
    do {
      try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations, clock: clock)
      Issue.record("uninstall passed an in-flight spawn")
    } catch let error as OperationError {
      #expect(error.message.hasPrefix("localStopFailed: "))
    }
    #expect(access(receipt, F_OK) == 0, "even stale receipts are untouched until publication ends")
  }

  @Test func uninstallDoesNotSignalAReusedLeaderIdentityEvenWithALockedReceipt() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let directory = home.operations + "/" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let pid = try ExecSupervisor.launchReaped(["/bin/sleep", "60"])
    defer { _ = killpg(pid, SIGKILL) }
    let path = directory + "/.lock"
    let receipt = try ProcessReceipt(path: path, process: pid)
    defer { receipt.close() }
    var birth: UInt64 = 0
    try #require(exec_process_birth(pid, &birth) == 0)
    let wrong = Array("\(pid) \(birth + 1)".utf8)
    try #require(ftruncate(receipt.descriptor, 0) == 0)
    try #require(wrong.withUnsafeBytes { pwrite(receipt.descriptor, $0.baseAddress, $0.count, 0) } == wrong.count)
    do {
      try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
      Issue.record("a mismatched leader birth anchor was accepted")
    } catch let error as OperationError {
      #expect(error.message.contains(path))
    }
    #expect(kill(pid, 0) == 0, "the unrelated process group must remain alive")
  }

  @Test func uninstallRefusesMalformedLockedReceipts() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let directory = home.operations + "/" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let path = directory + "/.lock"
    let lock = exec_lock_file(path, 1)
    try #require(lock >= 0)
    defer { exec_close(lock) }
    do {
      try await ExecSupervisor.stopInstalled(operationsDirectory: home.operations)
      Issue.record("malformed live receipt was ignored")
    } catch let error as OperationError {
      #expect(error.code == .supervisorUnavailable)
      #expect(error.message.hasPrefix("localStopFailed: "))
      #expect(error.message.contains(path))
    }
  }

  @Test func withComputerAgentServesInjectedBackendsHoldsTheLockAndUnwindsOnSuccessAndThrow() async throws {
    // ctl.sock lands beside the operations root, so the home must be short and private.
    let home = try MachineHome()
    defer { home.remove() }
    let root = home.operations
    let statused = Mutex<[String]>([])
    let files = ComputerFileSystem(
      status: { path in statused.withLock { $0.append(path) }; throw OperationError(.fileUnavailable) },
      read: { _, _, _ in throw OperationError(.fileUnavailable) },
      search: ComputerFileSystem.local.search,
    )
    struct Boom: Error {}
    for fails in [false, true] {
      let escaped = Mutex<ComputerAgent?>(nil)
      let ran = Mutex(false)
      let retainedLock = Mutex<Int32?>(nil)
      defer { if let descriptor = retainedLock.withLock({ $0 }) { exec_close(descriptor) } }
      do {
        let value = try await ExecSupervisor.withComputerAgent(machine: "test", operationsDirectory: root, executable: "/bin/false", files: files, kinds: [AnyOperationKind(NoteKind())]) { agent, _ in
          ran.withLock { $0 = true }
          escaped.withLock { $0 = agent }
          let duplicate = try retainAgentLock(root)
          retainedLock.withLock { $0 = duplicate }
          let second = exec_lock_agent(root)
          #expect(second < 0, "the lock is held while the body runs")
          if second >= 0 { exec_close(second) }
          let description = try await agent.handler(Request(url: URL(string: "https://agent/machine/v2/machines/test")!)).body.json(MachineDescription.self)
          #expect(description.acceptingStarts)
          #expect(description.kinds.map(\.name) == ["exec.v1", "read.v1", "search.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1", "note.v1"])
          let path = "/injected-\(fails)"
          let read = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + UUID().uuidString)!, method: .post, body: try .json(StartRequest(kind: "read.v1", input: ["path": .string(path)])))
          #expect(try await agent.handler(read).status.code == 201)
          let deadline = ContinuousClock.now + .seconds(10)
          while !statused.withLock({ $0.contains(path) }), ContinuousClock.now < deadline { try await ContinuousClock().sleep(for: .milliseconds(10)) }
          #expect(statused.withLock { $0.contains(path) }, "read.v1 runs over the injected file system")
          if fails { throw Boom() }
          return 7
        }
        #expect(!fails)
        #expect(value == 7)
      } catch is Boom { #expect(fails, "the body's own error propagates unchanged") }
      #expect(ran.withLock { $0 })
      let lock = exec_lock_agent(root)
      #expect(lock >= 0, "the lock is released when the body returns or throws")
      if lock >= 0 { exec_close(lock) }
      let agent = try #require(escaped.withLock { $0 })
      let start = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + UUID().uuidString)!, method: .post, body: try .json(StartRequest(kind: "read.v1", input: ["path": "/tmp/not-opened"])))
      #expect(try await agent.handler(start).body.json(ErrorEnvelope.self).error.code == .leaving, "the in-process runtime is shut down")
    }
  }

  @Test func composedWorkersRunLoopLivesExactlyAsLongAsTheBody() async throws {
    // ctl.sock lands beside the operations root, so the home must be short and private.
    let home = try MachineHome()
    defer { home.remove() }
    let launched = Mutex<[String]>([])
    @Sendable func waitForLaunches(_ count: Int) async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while launched.withLock({ $0.count }) < count {
        guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
        try await ContinuousClock().sleep(for: .milliseconds(10))
      }
    }
    try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: home.operations, executable: "/bin/false", files: .local, kinds: [], launch: { arguments in
      launched.withLock { $0.append(arguments[3]) }
      return nil
    }) { _, _ in
      // A launched worker whose directory is gone is gone; the run loop launches the next.
      try await waitForLaunches(1)
      WorkerDirectory.remove(launched.withLock { $0[0] })
      try await waitForLaunches(2)
    }
    WorkerDirectory.remove(launched.withLock { $0[1] })
    try await ContinuousClock().sleep(for: .milliseconds(500))
    #expect(launched.withLock { $0.count } == 2, "the run loop stopped with the body")
  }
}

private struct NoteKind: OperationKind {
  struct Input: Decodable, Sendable {}
  let descriptor = KindDescriptor("note.v1", inputSchema: ["type": "object"], resultSchema: ["type": "string"], deliveryPolicy: .boundedResult)
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> String { "" }
}

private func retainAgentLock(_ root: String) throws -> Int32 {
  var target = stat()
  try #require(stat(root + "/.agent.lock", &target) == 0)
  for entry in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
    guard let descriptor = Int32(entry) else { continue }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino else { continue }
    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    try #require(duplicate >= 0)
    return duplicate
  }
  throw OperationError(.invalidConfiguration, message: "agent lock descriptor not found")
}
