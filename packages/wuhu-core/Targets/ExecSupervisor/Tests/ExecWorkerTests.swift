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
@testable import ExecSupervisor
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import Synchronization
import Testing

/// The worker's side without a process: its lifetime rule, and the operation protocol behind its nonce and start admission.
@Suite struct ExecWorkerTests {
  func worker(_ clock: OperationClock = .continuous, directory: String = "/tmp/w313-absent") throws -> ExecWorker {
    try ExecWorker(manifest: WorkerManifest(machine: "test", worker: UUID(), nonce: UUID().uuidString + UUID().uuidString, socket: "/tmp/unused/ctl.sock"), directory: directory, clock: clock)
  }

  @Test func aWorkerLivesWhileLinkedAndCurrentOrHoldingOperations() async throws {
    let now = Mutex(Duration.zero)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { _ in try await ContinuousClock().sleep(for: .milliseconds(1)) })
    let fresh = try worker(clock)
    #expect(!(await fresh.shouldExit()), "a fresh worker waits for its first link")
    now.withLock { $0 = ExecWorker.firstLinkGrace }
    #expect(await fresh.shouldExit(), "an agent that never linked it is gone")

    let current = try worker(clock)
    await current.accepted(.init(accepted: true, current: true))
    #expect(!(await current.shouldExit()))
    await current.unlinked()
    #expect(await current.shouldExit(), "unlinked and idle: a restarted agent launches its own current worker")

    let earlier = try worker(clock)
    await earlier.accepted(.init(accepted: true, current: false))
    #expect(await earlier.shouldExit())

    let refused = try worker(clock)
    await refused.refuse(.unknownWorker)
    #expect(await refused.shouldExit(), "a refused worker never waits for a link")
  }

  /// A start is in the inventory before it runs. A worker not linked, not current, or marked superseded by a newer agent admits
  /// none, and a refused start leaves the inventory as it was.
  @Test func aStartIsInTheInventoryBeforeItRunsAndASupersededWorkerAdmitsNone() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try #require(mkdir(home.workers, 0o700) == 0)
    let id = UUID()
    let path = WorkerDirectory.path(workers: home.workers, id)
    let manifest = WorkerManifest(machine: "test", worker: id, nonce: UUID().uuidString + UUID().uuidString, socket: home.rendezvous)
    try WorkerDirectory.create(path, manifest)
    let worker = try ExecWorker(manifest: manifest, directory: path)
    func start(_ operation: UUID) async throws -> OperationError? {
      var request = execRequest(operation, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false])))
      request.headers["X-Wuhu-Supervisor-Nonce"] = manifest.nonce
      let response = try await worker.handler(request)
      return response.status.code == 201 ? nil : try await response.body.json(ErrorEnvelope.self).error
    }
    #expect(try await start(UUID())?.message == Unavailable.workerNotCurrent.rawValue, "not linked")
    await worker.accepted(.init(accepted: true, current: false))
    #expect(try await start(UUID())?.message == Unavailable.workerNotCurrent.rawValue, "not current")
    await worker.accepted(.init(accepted: true, current: true))
    let admitted = UUID()
    #expect(try await start(admitted) == nil)
    #expect(try WorkerDirectory.inventory(path).retained == [admitted])
    #expect(try WorkerDirectory.inventory(path).unsettled == [admitted])
    WorkerDirectory.supersede(path)
    #expect(try await start(UUID())?.message == Unavailable.workerNotCurrent.rawValue)
    #expect(try WorkerDirectory.inventory(path).retained == [admitted])
    #expect(try await start(UUID())?.message == Unavailable.workerNotCurrent.rawValue, "superseded for good")
    await worker.agent.shutdown()
  }

  /// A request for a start being admitted waits for the admission's end, and its caller's cancellation ends the wait.
  @Test func aRequestForAStartBeingAdmittedWaitsForItsAnswer() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try #require(mkdir(home.workers, 0o700) == 0)
    let manifest = WorkerManifest(machine: "test", worker: UUID(), nonce: UUID().uuidString + UUID().uuidString, socket: home.rendezvous)
    let path = WorkerDirectory.path(workers: home.workers, manifest.worker)
    try WorkerDirectory.create(path, manifest)
    let worker = try ExecWorker(manifest: manifest, directory: path)
    await worker.accepted(.init(accepted: true, current: true))
    let id = UUID()
    #expect(await worker.claim(id))
    let answered = Mutex(false)
    let waiting = Task { await worker.admitted(id); answered.withLock { $0 = true } }
    let cancelled = Task { await worker.admitted(id) }
    try await ContinuousClock().sleep(for: .milliseconds(100))
    #expect(!answered.withLock { $0 })
    cancelled.cancel()
    await cancelled.value
    #expect(!answered.withLock { $0 })
    await worker.unclaim(id)
    await waiting.value
    #expect(answered.withLock { $0 })
    await worker.agent.shutdown()
  }

  /// Only its agent, proved by the manifest nonce, reaches a worker's operations.
  @Test func aWorkerRefusesARequestWithoutItsNonce() async throws {
    let worker = try worker()
    for nonce in [nil, "0" + String(repeating: "f", count: 71)] {
      var request = execRequest(UUID())
      if let nonce { request.headers["X-Wuhu-Supervisor-Nonce"] = nonce }
      let response = try await worker.handler(request)
      #expect(response.status.code == 403)
      #expect(try await response.body.json(ErrorEnvelope.self).error.code == .machineNotAuthorized)
    }
    await worker.agent.shutdown()
  }
}
