#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import func ComputerFiles.fileOperationKinds
@testable import ExecSupervisor
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import class OperationRuntime.OperationAgent
import Synchronization
import Testing

@Suite struct ComputerAgentTests {
  func fixture(clock: OperationClock = .continuous, supervisorFiles: SupervisorFiles? = nil) throws -> ComputerAgent {
    let registry = try ExecSupervisorRegistry(machine: "test", operationsDirectory: "/tmp/ops", executable: "/tmp/wuhu", fetch: FetchClient { _ in throw OperationError(.supervisorUnavailable) }, authorize: { _, _ in }, files: supervisorFiles ?? .init(create: { _, _ in }, load: { _ in throw OperationError(.invalidConfiguration) }, list: { _ in [] }), clock: clock, launch: { _, _ in nil })
    let files = try OperationAgent(machine: "test", kinds: fileOperationKinds(), clock: clock, authorize: { _, _ in })
    return ComputerAgent(machine: "test", registry: registry, files: files, clock: clock)
  }

  func describe(ack: Bool = false) -> Request { Request(url: URL(string: "https://agent/machine/v2/machines/test" + (ack ? "?leaveAck=true" : ""))!) }

  @Test func combinesKindsAndRejectsOtherMachineBeforeDispatch() async throws {
    let agent = try fixture()
    let description = try await agent.handler(describe()).body.json(MachineDescription.self)
    #expect(Set(description.kinds.map(\.name)) == ["exec.v1", "read.v1", "find.v1", "grep.v1"])
    #expect(description.acceptingStarts)
    let response = try await agent.handler(Request(url: URL(string: "https://agent/machine/v2/machines/not-authorized")!))
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .machineNotAuthorized)
    #expect(try await agent.handler(describe(ack: true)).body.json(ErrorEnvelope.self).error.code == .invalidInput)
  }

  @Test func fileAndExecAdmissionShareOneActiveMachineCap() async throws {
    let agent = try fixture()
    let fileIDs = (0 ..< 32).map { _ in UUID() }
    for fileID in fileIDs {
      let request = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + fileID.uuidString)!, method: .post, body: try .json(StartRequest(kind: "read.v1", input: ["path": "/tmp/not-opened-before-run"])))
      #expect(try await agent.handler(request).status.code == 201)
    }
    let id = UUID()
    let request = Request(url: URL(string: "https://agent/machine/v2/machines/test/operations/" + id.uuidString)!, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false])))
    #expect(try await agent.handler(request).body.json(ErrorEnvelope.self).error.code == .capacityExceeded)
    #expect(!(await agent.registry.owns(id)))
    let fileID = fileIDs[0]
    var duplicate = request; duplicate.url = URL(string: "https://agent/machine/v2/machines/test/operations/" + fileID.uuidString)!
    #expect(try await agent.handler(duplicate).body.json(ErrorEnvelope.self).error.code == .operationExists)
    await agent.files.shutdown()
  }

  @Test func localLeaveWaitsForLogicalAcknowledgementNotConnectionClose() async throws {
    let agent = try fixture()
    let leave = Task { try await agent.controlHandler(Request(url: URL(string: "http://local/leave")!, method: .put)) }
    defer { leave.cancel() }
    while !(await agent.registry.leaving) { try await ContinuousClock().sleep(for: .milliseconds(1)) }
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
    let agent = try fixture(clock: clock)
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
    let agent = try fixture(clock: clock, supervisorFiles: files)
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
}
