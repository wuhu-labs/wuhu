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
  func fixture(clock: OperationClock = .continuous, supervisorFiles: SupervisorFiles? = nil) throws -> (ComputerAgent, ExecSupervisorRegistry) {
    let registry = try ExecSupervisorRegistry(machine: "test", operationsDirectory: "/tmp/ops", executable: "/tmp/wuhu", fetch: FetchClient { _ in throw OperationError(.supervisorUnavailable) }, authorize: { _, _ in }, files: supervisorFiles ?? .init(create: { _, _ in }, load: { _ in throw OperationError(.invalidConfiguration) }, list: { _ in [] }), clock: clock, launch: { _, _ in nil })
    return (try ComputerAgent(machine: "test", external: registry.external, clock: clock), registry)
  }

  func describe(ack: Bool = false) -> Request { Request(url: URL(string: "https://agent/machine/v2/machines/test" + (ack ? "?leaveAck=true" : ""))!) }

  @Test func combinesKindsAndRejectsOtherMachineBeforeDispatch() async throws {
    let (agent, _) = try fixture()
    let description = try await agent.handler(describe()).body.json(MachineDescription.self)
    #expect(Set(description.kinds.map(\.name)) == ["exec.v1", "read.v1", "find.v1", "grep.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1"])
    #expect(description.acceptingStarts)
    let response = try await agent.handler(Request(url: URL(string: "https://agent/machine/v2/machines/not-authorized")!))
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .machineNotAuthorized)
    #expect(try await agent.handler(describe(ack: true)).body.json(ErrorEnvelope.self).error.code == .invalidInput)
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

  @Test func localLeaveWaitsForLogicalAcknowledgementNotConnectionClose() async throws {
    let (agent, registry) = try fixture()
    let leave = Task { try await agent.controlHandler(Request(url: URL(string: "http://local/leave")!, method: .put)) }
    defer { leave.cancel() }
    while !(await registry.leaving) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
    #expect(!(await agent.leaveAcknowledged))
    #expect(try await agent.handler(describe()).body.json(ErrorEnvelope.self).error.code == .leaving)
    #expect(!(await agent.leaveAcknowledged))
    #expect(try await agent.handler(describe(ack: true)).body.json(ErrorEnvelope.self).error.code == .leaving)
    #expect(try await leave.value.body.json(Bool.self))
    let start = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + UUID().uuidString)!, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: .null)))
    #expect(try await agent.handler(start).body.json(ErrorEnvelope.self).error.code == .leaving)
  }

  @Test func lostLeaveAckTimesOutAndCannotLaterClaimDetached() async throws {
    let now = Mutex(Duration.zero)
    let holder = Mutex<ComputerAgent?>(nil)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { duration in
      if duration >= .seconds(1) {
        while let agent = holder.withLock({ $0 }), !(await agent.drainCompleted) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
        now.withLock { $0 += duration }; return
      }
      try await ContinuousClock().sleep(for: .milliseconds(1))
    })
    let (agent, _) = try fixture(clock: clock)
    holder.withLock { $0 = agent }
    let failure = try await agent.controlHandler(Request(url: URL(string: "http://local/leave")!, method: .put)).body.json(ErrorEnvelope.self).error
    #expect(failure.code == .requestDeadline)
    #expect(failure.message == "leaveUnacknowledged")
    let response = try await agent.handler(describe())
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .requestDeadline)
    #expect(try await agent.handler(describe(ack: true)).body.json(ErrorEnvelope.self).error.code == .invalidInput)
    #expect(!(await agent.leaveAcknowledged))
  }

  @Test func timeoutDuringPendingSupervisorCreationIsDrainFailedNotMissingAck() async throws {
    let now = Mutex(Duration.zero)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { duration in
      if duration >= .seconds(1) { now.withLock { $0 += duration }; return }
      try await ContinuousClock().sleep(for: .milliseconds(1))
    })
    let files = SupervisorFiles(create: { _, _ in try await ContinuousClock().sleep(for: .seconds(300)) }, load: { _ in throw OperationError(.invalidConfiguration) }, list: { _ in [] })
    let (agent, _) = try fixture(clock: clock, supervisorFiles: files)
    let request = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + UUID().uuidString)!, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false])))
    let start = Task { try await agent.handler(request) }
    defer { start.cancel() }
    while await agent.pending.isEmpty { try await ContinuousClock().sleep(for: .milliseconds(1)) }
    let response = try await agent.controlHandler(Request(url: URL(string: "http://local/leave")!, method: .put))
    let error = try await response.body.json(ErrorEnvelope.self).error
    #expect(error.code == .requestDeadline)
    #expect(error.message == "drainFailed")
    #expect(!(await agent.drainCompleted))
    #expect(!(await agent.leaveAcknowledged))
    #expect(await agent.pending.count == 1)
    start.cancel(); _ = try await start.value
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
      walk: { _, _ in throw OperationError(.fileUnavailable) },
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
          #expect(description.kinds.map(\.name) == ["exec.v1", "read.v1", "find.v1", "grep.v1", "stat.v1", "list.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1", "note.v1"])
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

  @Test func composedRegistryRunLoopLivesExactlyAsLongAsTheBody() async throws {
    // ctl.sock lands beside the operations root, so the home must be short and private.
    let home = try MachineHome()
    defer { home.remove() }
    let root = home.operations
    // Not our child: the run loop's nonblocking reap fails ECHILD and drops it, which is how a live loop shows without spawning anything.
    let registry = try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: root, executable: "/bin/false", files: .local, kinds: []) { _, registry in
      await registry.track(Int32.max)
      let deadline = ContinuousClock.now + .seconds(10)
      while await registry.childPIDs.contains(Int32.max), ContinuousClock.now < deadline { try await ContinuousClock().sleep(for: .milliseconds(10)) }
      #expect(!(await registry.childPIDs.contains(Int32.max)), "registry.run() polls tracked children while the body runs")
      return registry
    }
    await registry.track(Int32.max)
    try await ContinuousClock().sleep(for: .milliseconds(400))
    #expect(await registry.childPIDs.contains(Int32.max), "registry.run() stopped with the body")
  }
}

private struct NoteKind: OperationKind {
  struct Input: Decodable, Sendable {}
  let descriptor = KindDescriptor("note.v1", inputSchema: ["type": "object"], resultSchema: ["type": "string"], deliveryPolicy: .boundedResult)
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> String { "" }
}

extension ExecSupervisorRegistry {
  func track(_ pid: Int32) { childPIDs.insert(pid) }
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
