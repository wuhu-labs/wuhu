import TaskLifetime
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
import Clocks
@testable import ComputerFiles
@testable import ExecSupervisor
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import struct OperationProtocol.Verdict
import class OperationRuntime.OperationAgent
import Synchronization
import Testing

/// The agent's side of the exec workers, driven only through what it offers: the external kind the computer agent calls, the
/// links workers dial, and retirement. Every worker is a fake: a directory whose lock the test holds while it "runs", and a
/// link whose answers the test scripts.
@Suite struct WorkersTests {
  /// The workers the agent launched, in order: each one's lock is held, as its process would, until it is killed.
  final class Launches: Sendable {
    let launched = Mutex<[UUID]>([])
    let locks = Mutex<[(UUID, Int32)]>([])

    func launch(_ arguments: [String]) throws -> Int32? {
      let path = arguments[3]
      guard let id = UUID(uuidString: String(path.split(separator: "/").last ?? "")), let fd = WorkerDirectory.lock(path, create: true) else { throw OperationError(.invalidConfiguration) }
      launched.withLock { $0.append(id) }
      locks.withLock { $0.append((id, fd)) }
      return nil
    }

    var ids: [UUID] { launched.withLock { $0 } }

    func kill(_ id: UUID) {
      let fds = locks.withLock { locks in
        defer { locks.removeAll { $0.0 == id } }
        return locks.filter { $0.0 == id }.map(\.1)
      }
      for fd in fds { exec_close(fd) }
    }

    func killAll() { for id in locks.withLock({ $0.map(\.0) }) { kill(id) } }
  }

  struct Machine {
    let home: MachineHome
    let workers: ExecWorkers
    let launches: Launches

    var kind: ExternalKind { workers.external }

    func handle(_ request: Request) async throws -> Response { try await kind.handler(request) }

    func code(_ request: Request) async throws -> OperationError.Code { try await handle(request).body.json(ErrorEnvelope.self).error.code }

    func error(_ request: Request) async throws -> OperationError { try await handle(request).body.json(ErrorEnvelope.self).error }

    func usage() async throws -> ExternalUsage { try await kind.usage() }

    /// The worker the agent launched most recently, once it has launched `count`.
    func launched(_ count: Int = 1) async throws -> UUID {
      try await until("\(count) workers launched") { launches.ids.count >= count }
      return try #require(launches.ids.last)
    }

    func manifest(_ id: UUID) throws -> WorkerManifest { try WorkerDirectory.load(WorkerDirectory.path(workers: home.workers, id)) }

    @discardableResult
    func link(_ id: UUID, _ client: FetchClient, abort: @escaping @Sendable () -> Void = {}) async throws -> (generation: UInt64, reply: Rendezvous.Reply) {
      try await workers.link(hello(id), client: client, abort: abort)
    }

    func unlink(_ id: UUID, generation: UInt64) async throws { await workers.unlink(try hello(id), generation: generation) }

    func hello(_ id: UUID) throws -> Rendezvous.Hello {
      Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: "test", worker: id, nonce: try manifest(id).nonce)
    }
  }

  /// The agent with its run loop, for the duration of `body`.
  func machine<R: Sendable>(_ home: MachineHome, clock: OperationClock = .continuous, disclaim: Bool = false, _ body: @Sendable (Machine) async throws -> R) async throws -> R {
    let launches = Launches()
    defer { launches.killAll() }
    let workers = try ExecWorkers(machine: "test", operationsDirectory: home.operations, executable: "/bin/false", disclaimResponsibility: disclaim, clock: clock, launch: { try launches.launch($0) }, authorize: { _, _ in })
    try await workers.recover()
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await workers.run() }
      defer { group.cancelAll() }
      return try await body(Machine(home: home, workers: workers, launches: launches))
    }
  }

  /// A link whose every request `operations` answers.
  func client(_ operations: @escaping @Sendable (Request) async throws -> Response = { _ in try unknown() }) -> FetchClient {
    FetchClient { request in try await operations(request) }
  }

  func start(_ id: UUID, caller: StartRequest.Caller? = nil) throws -> Request {
    execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false], caller: caller)))
  }

  func ack(_ id: UUID, _ channel: String, _ token: UUID) -> Request { execRequest(id, query: "?channel=\(channel)&after=0&terminalAck=\(token)") }

  /// A worker directory left by an earlier agent's worker, with its inventory; `alive` holds its lock as its running process would.
  func recovered(_ home: MachineHome, _ inventory: WorkerInventory = .init(), alive: Bool = true) throws -> (id: UUID, path: String, lock: Int32?) {
    if access(home.workers, F_OK) != 0 { try #require(mkdir(home.workers, 0o700) == 0) }
    let id = UUID()
    let path = WorkerDirectory.path(workers: home.workers, id)
    try WorkerDirectory.create(path, WorkerManifest(machine: "test", worker: id, nonce: UUID().uuidString + UUID().uuidString, socket: home.rendezvous))
    try WorkerDirectory.writeInventory(path, inventory)
    if alive {
      let lock = try #require(WorkerDirectory.lock(path, create: true))
      return (id, path, lock)
    }
    try WorkerDirectory.writeFile(path + "/.lock", Data())
    return (id, path, nil)
  }

  func isWorkerLost(_ error: OperationError) -> Bool {
    error.code == .unknownOperation && error.details == ["outcome": "unknown", "reason": .string(UnknownOutcome.workerLost.rawValue)]
  }

  @Test func aStartGoesToTheCurrentWorkerWithItsNonceAndCallerAndItsPollsFollow() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let id = UUID()
      let seen = Mutex<[(String?, StartRequest?)]>([])
      let worker = try await machine.launched()
      try await machine.link(worker, client { request in
        let start = request.method == .post ? try? await request.json(StartRequest.self, upTo: 1 << 20) : nil
        seen.withLock { $0.append((request.headers["X-Wuhu-Supervisor-Nonce"], start)) }
        return try snapshot(id)
      })
      let caller = StartRequest.Caller(session: "quick-breeze-badge", title: "Backend coder", group: "shared")
      #expect(try await machine.handle(start(id, caller: caller)).status.code == 201)
      #expect(try await machine.handle(execRequest(id)).status.code == 201)
      #expect(seen.withLock { $0.map(\.0) } == Array(repeating: try machine.manifest(worker).nonce, count: 2))
      #expect(seen.withLock { $0.first?.1?.caller } == caller)
      #expect(await machine.kind.owns(id))
    }
  }

  @Test func aStartsReservationIsWhatTheWorkerReports() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let id = UUID()
      try await machine.link(try await machine.launched(), client { _ in try snapshot(id, reservation: 1000) })
      #expect(try await machine.handle(start(id)).status.code == 201)
      #expect(try await machine.usage() == ExternalUsage(operations: [id: 1000 + ExecWorkers.readStaging]))
    }
  }

  /// A start whose answer never arrived may be running, so it stays charged; one the worker refused is forgotten.
  @Test func aStartWhoseAnswerIsLostStaysChargedAndARefusedOneDoesNot() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let answer = Mutex(0)
      try await machine.link(try await machine.launched(), client { _ in
        switch answer.withLock({ $0 }) {
        case 0: throw OperationError(.supervisorUnavailable)
        case 1: return try .json(ErrorEnvelope(.init(.invalidInput)), status: .init(code: 400))
        default: return try .json(ErrorEnvelope(.init(.operationExists)), status: .conflict)
        }
      })
      let lost = UUID(), refused = UUID(), existing = UUID()
      #expect(try await machine.handle(start(lost)).status.code == OperationError(.supervisorUnavailable).statusCode)
      answer.withLock { $0 = 1 }
      #expect(try await machine.handle(start(refused)).status.code == 400)
      answer.withLock { $0 = 2 }
      #expect(try await machine.handle(start(existing)).status.code == 409)
      #expect(Set(try await machine.usage().operations.keys) == [lost, existing])
      #expect(await !machine.kind.owns(refused))
    }
  }

  /// A recovered worker is marked superseded, then its inventory is read: every operation it holds is charged in full until a
  /// snapshot says otherwise (a settled one nothing) and taken; any other id is no worker's, even before it links.
  @Test func aRecoveredWorkersInventoryIsChargedAndTakenBeforeItLinks() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let running = UUID(), settled = UUID()
    let worker = try recovered(home, .init(retained: [running, settled], unsettled: [running]))
    defer { if let lock = worker.lock { exec_close(lock) } }
    try await machine(home) { machine throws in
      #expect(WorkerDirectory.superseded(worker.path))
      #expect(try await machine.usage() == ExternalUsage(operations: [running: ExecWorkers.fullReservation, settled: 0]))
      #expect(await machine.kind.owns(running))
      #expect(await machine.kind.owns(settled))
      #expect(try await machine.code(start(running)) == .operationExists)
      let began = ContinuousClock().now
      #expect(try await machine.code(execRequest(UUID())) == .unknownOperation)
      #expect(ContinuousClock().now - began < .seconds(1), "an id no inventory names is unknown at once")
      // An operation it holds waits for it to link, and is unavailable, never unknown, while it does not.
      #expect(try await machine.error(execRequest(running)).message == Unavailable.workerNotConnected.rawValue)
      #expect(await machine.kind.owns(running))
    }
  }

  /// A recovered worker that never links (here: stopped) holds only what its inventory names; the rest of the budget stays open.
  @Test func aRecoveredWorkerThatNeverLinksBlocksOnlyWhatItHolds() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let held = Set((0 ..< 3).map { _ in UUID() })
    let worker = try recovered(home, .init(retained: held, unsettled: held))
    defer { if let lock = worker.lock { exec_close(lock) } }
    try await machine(home) { machine in
      let id = UUID()
      try await machine.link(try await machine.launched(), client { _ in try snapshot(id) })
      #expect(try await machine.handle(start(id)).status.code == 201)
      #expect(Set(try await machine.usage().operations.keys) == held.union([id]))
    }
  }

  /// An inventory that cannot be read may name anything: that worker is charged the whole budget, every unrouted id is
  /// unavailable until the inventory it writes for its hello is read.
  @Test func anUnreadableInventoryIsChargedTheWholeBudgetUntilTheWorkerLinks() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let worker = try recovered(home)
    defer { if let lock = worker.lock { exec_close(lock) } }
    _ = unlink(worker.path + "/operations.json")
    try WorkerDirectory.writeFile(worker.path + "/operations.json", Data("{".utf8))
    try await machine(home) { machine in
      let limits = OperationLimits()
      #expect(try await machine.usage() == ExternalUsage(receipts: limits.receipts, bufferBytes: limits.bufferBytes))
      #expect(try await machine.error(execRequest(UUID())).message == Unavailable.workerNotConnected.rawValue)
      let held = UUID()
      _ = unlink(worker.path + "/operations.json")
      try WorkerDirectory.writeInventory(worker.path, .init(retained: [held], unsettled: [held]))
      try await machine.link(worker.id, client())
      #expect(try await machine.usage() == ExternalUsage(operations: [held: ExecWorkers.fullReservation]))
      #expect(try await machine.code(execRequest(UUID())) == .unknownOperation)
    }
  }

  /// The inventory a recovered worker writes for its first hello is the truth: what it released since is no longer its, what it
  /// dropped unsettled is lost, and what settled is charged nothing.
  @Test func aRecoveredWorkersFirstHelloReconcilesWhatItHolds() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let released = UUID(), dropped = UUID(), settling = UUID(), running = UUID()
    let all: Set<UUID> = [released, dropped, settling, running]
    let worker = try recovered(home, .init(retained: all, unsettled: all))
    defer { if let lock = worker.lock { exec_close(lock) } }
    try await machine(home) { machine in
      #expect(Set(try await machine.usage().operations.keys) == all)
      try WorkerDirectory.writeInventory(worker.path, .init(retained: [settling, running], unsettled: [running], lost: [dropped]))
      #expect(try await machine.link(worker.id, client()).reply.current == false)
      #expect(try await machine.usage() == ExternalUsage(operations: [settling: 0, running: ExecWorkers.fullReservation]))
      #expect(isWorkerLost(try await machine.error(execRequest(dropped))))
      #expect(try await machine.error(execRequest(released)).details == nil, "released, not lost")
      #expect(try WorkerDirectory.ids(home.workers + "/lost.json") == [dropped])
    }
  }

  /// The inventory is a snapshot: an operation that settles after it was written reaches the agent through its ordinary poll,
  /// which releases its charge.
  @Test func anOperationThatSettlesAfterTheInventoryReleasesItsChargeThroughItsPoll() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let id = UUID(), token = UUID()
    let worker = try recovered(home, .init(retained: [id], unsettled: [id]))
    defer { if let lock = worker.lock { exec_close(lock) } }
    try await machine(home) { machine in
      #expect(try await machine.usage() == ExternalUsage(operations: [id: ExecWorkers.fullReservation]))
      try await machine.link(worker.id, client { _ in try finished(id, token: token) })
      #expect(try await machine.handle(ack(id, "stdout", token)).status.code == 200)
      #expect(try await machine.usage() == ExternalUsage(operations: [id: 0]))
      #expect(try await machine.handle(ack(id, "stderr", token)).status.code == 200)
      #expect(try await machine.usage() == ExternalUsage())
    }
  }

  /// The current worker died: what it recorded and what the agent forwarded to it unsettled is lost, on disk before its
  /// directory goes, and a new worker takes its place.
  @Test func aDeadWorkersUnsettledOperationsAreLostAndItIsReplaced() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let recorded = UUID(), forwarded = UUID(), settled = UUID(), token = UUID()
      let dead = try await machine.launched()
      try await machine.link(dead, client { request in
        let id = try #require(UUID(uuidString: String(request.url.path.split(separator: "/")[5])))
        return id == settled ? try finished(id, token: token) : try snapshot(id)
      })
      for id in [forwarded, settled] { #expect(try await machine.handle(start(id)).status.code < 300) }
      #expect(try await machine.handle(ack(settled, "stdout", token)).status.code == 200)
      let path = WorkerDirectory.path(workers: home.workers, dead)
      try WorkerDirectory.writeInventory(path, .init(retained: [recorded, forwarded, settled], unsettled: [recorded, forwarded]))
      machine.launches.kill(dead)
      let replacement = try await machine.launched(2)
      #expect(replacement != dead)
      try await until("the dead worker's directory is removed") { access(path, F_OK) != 0 }
      #expect(try WorkerDirectory.ids(home.workers + "/lost.json") == [recorded, forwarded], "the loss is on disk before the evidence goes")
      for id in [recorded, forwarded] { #expect(isWorkerLost(try await machine.error(execRequest(id)))) }
      #expect(try await machine.error(execRequest(settled)).details == nil)
      try await machine.link(replacement, client())
    }
  }

  /// Workers that died or dropped operations while no agent ran leave that on disk; the agent that finds it keeps it in its
  /// ledger, so every agent after it still reports it.
  @Test func lossEvidenceSurvivesTwoAgentRestarts() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let crashed = UUID(), dropped = UUID(), settled = UUID()
    let died = try recovered(home, .init(retained: [crashed, settled], unsettled: [crashed]), alive: false)
    let exited = try recovered(home, .init(lost: [dropped]), alive: false)
    try await machine(home) { machine throws in
      #expect(access(died.path, F_OK) != 0 && access(exited.path, F_OK) != 0)
      for id in [crashed, dropped] { #expect(isWorkerLost(try await machine.error(execRequest(id)))) }
    }
    try await machine(home) { machine in
      #expect(await machine.kind.owns(crashed))
      let error = try await machine.error(execRequest(crashed))
      #expect(isWorkerLost(error))
    }
    try await machine(home) { machine in
      _ = await machine.workers.retire(.turnedOff, deadline: .milliseconds(50))
    }
  }

  /// A worker that says it does not know an operation last seen unsettled dropped it; one seen settled was just released.
  @Test func anUnknownAnswerForAnUnsettledOperationIsALoss() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let unsettled = UUID(), settled = UUID(), token = UUID()
      let forgotten = Mutex(false)
      try await machine.link(try await machine.launched(), client { request in
        guard !forgotten.withLock({ $0 }) else { return try unknown() }
        let id = try #require(UUID(uuidString: String(request.url.path.split(separator: "/")[5])))
        return id == settled ? try finished(id, token: token) : try snapshot(id)
      })
      for id in [unsettled, settled] { #expect(try await machine.handle(start(id)).status.code < 300) }
      #expect(try await machine.handle(ack(settled, "stdout", token)).status.code == 200)
      forgotten.withLock { $0 = true }
      for id in [unsettled, settled] { #expect(try await machine.code(execRequest(id)) == .unknownOperation) }
      #expect(isWorkerLost(try await machine.error(execRequest(unsettled))))
      #expect(try await machine.error(execRequest(settled)).details == nil)
    }
  }

  /// A worker drops a receipt one retention window after its caller's last request; the agent forgets it a second later, as
  /// lost unless it was settled.
  @Test func anOperationUnrequestedForTheReceiptRetentionIsForgottenAndLostUnlessSettled() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let now = Mutex(Duration.zero)
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { _ in try await ContinuousClock().sleep(for: .milliseconds(1)) })
    try await machine(home, clock: clock) { machine in
      let id = UUID(), settled = UUID(), token = UUID()
      try await machine.link(try await machine.launched(), client { request in
        let operation = try #require(UUID(uuidString: String(request.url.path.split(separator: "/")[5])))
        return operation == settled ? try finished(operation, token: token) : try snapshot(operation)
      })
      for operation in [id, settled] { #expect(try await machine.handle(start(operation)).status.code < 300) }
      #expect(try await machine.handle(ack(settled, "stdout", token)).status.code == 200)
      now.withLock { $0 = OperationAgent.receiptRetention }
      try await ContinuousClock().sleep(for: .milliseconds(100))
      #expect(Set(try await machine.usage().operations.keys) == [id, settled])
      now.withLock { $0 = OperationAgent.receiptRetention + .seconds(1) }
      try await until("the expired operations are forgotten") { (try? await machine.usage().operations.isEmpty) == true }
      #expect(isWorkerLost(try await machine.error(execRequest(id))))
      #expect(try await machine.error(execRequest(settled)).details == nil)
    }
  }

  /// Retirement stops what runs (reason `retired`) and cuts every link; a worker that redials hears it is not current.
  @Test func aRetiredAgentStopsItsOperationsAndNoWorkerIsCurrent() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let id = UUID()
      let reasons = Mutex<[String]>([])
      let answer: @Sendable (Request) async throws -> Response = { request in
        if request.url.path.hasSuffix("/stop") {
          let reason = (try? await request.json(StopRequest.self, upTo: 1024))?.reason ?? ""
          reasons.withLock { $0.append(reason) }
        }
        guard !reasons.withLock({ $0.isEmpty }) else { return try snapshot(id) }
        return try .json(OperationSnapshot(operation: id, verdict: Verdict(.stopped, reason: StopReason.retired.rawValue), terminalToken: UUID(), finalOffsets: [:], outputConsumed: false))
      }
      let aborted = Mutex(false)
      let worker = try await machine.launched()
      #expect(try await machine.link(worker, client(answer), abort: { aborted.withLock { $0 = true } }).reply.current == true)
      #expect(try await machine.handle(start(id)).status.code == 201)
      #expect(await machine.workers.retire(.turnedOff, deadline: .seconds(5)) == 0)
      #expect(reasons.withLock { $0 } == [StopReason.retired.rawValue])
      #expect(aborted.withLock { $0 })
      #expect(try await machine.link(worker, client(answer)).reply.current == false)
      #expect(try await machine.code(start(UUID())) == .leaving)
    }
  }

  /// While a start is on its way, a worker that does not know the operation yet says nothing about it: a stop's early unknown
  /// keeps the route, and retirement waits for the start's answer, then stops what it started.
  @Test func aStartOnItsWayIsNeitherLostNorForgottenByRetirement() async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home) { machine in
      let id = UUID()
      let arrived = Mutex(false), released = Mutex(false), started = Mutex(false)
      let reasons = Mutex<[String]>([])
      try await machine.link(try await machine.launched(), client { request in
        if request.method == .post {
          arrived.withLock { $0 = true }
          while !released.withLock({ $0 }) { try await ContinuousClock().sleep(for: .milliseconds(5)) }
          started.withLock { $0 = true }
          return try snapshot(id)
        }
        guard started.withLock({ $0 }) else { return try unknown() }
        if request.url.path.hasSuffix("/stop") {
          let reason = (try? await request.json(StopRequest.self, upTo: 1024))?.reason ?? ""
          reasons.withLock { $0.append(reason) }
        }
        guard !reasons.withLock({ $0.isEmpty }) else { return try snapshot(id) }
        return try .json(OperationSnapshot(operation: id, verdict: Verdict(.stopped, reason: StopReason.retired.rawValue), terminalToken: UUID(), finalOffsets: [:], outputConsumed: false))
      })
      let starting = Task { try await machine.handle(start(id)).status.code }
      try await until("the start reaches the worker") { arrived.withLock { $0 } }
      #expect(try await machine.code(execRequest(id, suffix: "/stop", method: .put, body: .json(StopRequest(reason: "early")))) == .unknownOperation)
      #expect(await machine.kind.owns(id), "the early unknown did not drop the route")
      #expect(try await machine.error(execRequest(id)).details == nil, "nor record it lost")
      let retiring = Task { await machine.workers.retire(.turnedOff, deadline: .seconds(5)) }
      try await ContinuousClock().sleep(for: .milliseconds(300))
      #expect(reasons.withLock { $0.isEmpty })
      released.withLock { $0 = true }
      #expect(try await starting.value == 201)
      #expect(await retiring.value == 0)
      #expect(reasons.withLock { $0 } == [StopReason.retired.rawValue], "retirement stopped what the start began")
    }
  }

  /// Evidence that exists and cannot be read is never taken for none: a ledger that cannot be read fails recovery, and a dead
  /// worker whose inventory cannot be read keeps its directory; an id no route names may be its.
  @Test func unreadableLossEvidenceFailsRatherThanReadsAsNone() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let dead = try recovered(home, alive: false)
    _ = unlink(dead.path + "/operations.json")
    try WorkerDirectory.writeFile(dead.path + "/operations.json", Data("{".utf8))
    try await machine(home) { machine in
      #expect(access(dead.path, F_OK) == 0, "its directory stays as the evidence")
      let error = try await machine.error(execRequest(UUID()))
      #expect(error.details == ["outcome": "unknown", "reason": .string(UnknownOutcome.workerUnaccounted.rawValue)])
    }
    WorkerDirectory.remove(dead.path)
    let ledger = home.workers + "/lost.json"
    for content in [Data("[".utf8), Data(repeating: 0x20, count: WorkerDirectory.evidenceBytes + 1)] {
      _ = unlink(ledger)
      let fd = open(ledger, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      _ = content.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      _ = close(fd)
      let workers = try ExecWorkers(machine: "test", operationsDirectory: home.operations, executable: "/bin/false", launch: { _ in nil }, authorize: { _, _ in })
      await #expect(throws: OperationError.self) { try await workers.recover() }
    }
  }

  /// A writer refuses evidence larger than a reader takes.
  @Test func evidenceLargerThanAReaderTakesIsNotWritten() throws {
    let home = try MachineHome(); defer { home.remove() }
    try #require(mkdir(home.workers, 0o700) == 0)
    let many = Set((0 ..< WorkerDirectory.evidenceBytes / 36).map { _ in UUID() })
    #expect(throws: OperationError.self) { try WorkerDirectory.writeIDs(home.workers + "/lost.json", many) }
    #expect(try WorkerDirectory.ids(home.workers + "/lost.json").isEmpty)
  }

  @Test(arguments: [false, true]) func theResponsibilityPolicyIsInTheWorkersManifest(disclaim: Bool) async throws {
    let home = try MachineHome(); defer { home.remove() }
    try await machine(home, disclaim: disclaim) { machine in
      let worker = try await machine.launched()
      #expect(try machine.manifest(worker).disclaimResponsibility == (disclaim ? true : nil))
    }
  }

  /// A peer that never answers holds a request only to its deadline, and a cancelled caller not at all.
  @MainActor @Test func aRequestDeadlineAnswersWithoutWaitingForTheWork() async throws {
    let parked = Mutex<[CheckedContinuation<Void, Never>]>([])
    let scope = TaskScope()
    let client = FetchClient { _ in
      await withCheckedContinuation { continuation in parked.withLock { $0.append(continuation) } }
      return Response.text("late")
    }
    let request = Request(url: URL(string: "http://supervisor/identity")!)
    let clock = TestClock()
    let answered = Mutex(0)
    let timed = Task {
      defer { answered.withLock { $0 += 1 } }
      return try await ExecWorkers.exchange(scope: scope, request, client: client, nonce: "nonce", deadline: .milliseconds(200), operation: nil, clock: clock)
    }
    try await until("the exchange reaches the peer") { parked.withLock { $0.count } == 1 }
    try await until("the deadline fires") {
      await clock.advance(by: .milliseconds(200))
      return answered.withLock { $0 } == 1
    }
    do {
      _ = try await timed.value
      Issue.record("the deadline did not fire")
    } catch let error as OperationError { #expect(error.message == Unavailable.supervisorTimeout.rawValue) }
    let caller = Task {
      defer { answered.withLock { $0 += 1 } }
      return try await ExecWorkers.exchange(scope: scope, request, client: client, nonce: "nonce", deadline: .seconds(60), operation: nil, clock: clock)
    }
    try await until("the second exchange reaches the peer") { parked.withLock { $0.count } == 2 }
    caller.cancel()
    try await until("the cancelled exchange returns") { answered.withLock { $0 } == 2 }
    await #expect(throws: CancellationError.self) { try await caller.value }
    for continuation in parked.withLock({ $0 }) { continuation.resume() }
    await scope.close()
    #expect(scope.liveTasks.isEmpty)
  }
}

func snapshot(_ id: UUID, reservation: Int? = nil) throws -> Response {
  try .json(OperationSnapshot(operation: id, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, bufferReservationBytes: reservation), status: .init(code: 201))
}

/// A finished exec whose output was all read: an acknowledgement of `token` settles it.
func finished(_ id: UUID, token: UUID) throws -> Response {
  try .json(OperationSnapshot(operation: id, verdict: Verdict(.completed, result: ["termination": ["tag": "exit", "code": 0]]), terminalToken: token, finalOffsets: ["stdout": Offset(rawValue: 0), "stderr": Offset(rawValue: 0)], outputConsumed: true, bufferReservationBytes: 0))
}

func unknown() throws -> Response { try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound) }

func until(_ what: String, within limit: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async throws {
  let clock = ContinuousClock(); let deadline = clock.now + limit
  while !(await condition()) {
    guard clock.now < deadline else { Issue.record("timed out waiting: \(what)"); throw TestFailure.timeout }
    try await clock.sleep(for: .milliseconds(10))
  }
}
