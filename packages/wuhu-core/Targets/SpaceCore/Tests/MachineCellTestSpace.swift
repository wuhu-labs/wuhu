import Crypto
import Dispatch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import SpaceCore
import Synchronization
import Wuwei

final class MachineCellTestSpace: Sendable {
  let space: Space
  let writer: any DatabaseWriter
  let worker: Worker
  let machineBuffers: MachineBuffers
  private let scheduler = MachineCellTestScheduler()
  private let database: WuweiDatabase
  private let stopped = Mutex(false)

  private init(_ space: Space) async throws {
    self.space = space
    let writer = await space.writer
    self.writer = writer
    database = try WuweiDatabase(writer: writer)
    worker = Worker(id: "machine-cell-test-\(UUID())", storage: .shared(database), scheduler: scheduler, registrations: [.cell(MachineCell.self)])
    machineBuffers = MachineBuffers(worker: worker.id)
    worker.provide(machineBuffers)
  }

  static func inMemory() async throws -> MachineCellTestSpace { try await MachineCellTestSpace(Space.inMemory()) }
  static func open(file: URL) async throws -> MachineCellTestSpace { try await MachineCellTestSpace(Space.open(file: file)) }

  func addMachineV2(name: String) async throws -> (machine: MachineRecord, token: MintedJoinToken) {
    try await space.addMachineV2(name: name)
  }

  func drain() async { await scheduler.drain() }
  func holdNextTask() { scheduler.holdNextTask() }
  func stopHoldingNextTask() { scheduler.stopHoldingNextTask() }
  func advance(by milliseconds: Int64) { scheduler.advance(by: milliseconds) }
  var heldTaskCount: Int { scheduler.heldTaskCount }
  func releaseHeldTasks() { scheduler.releaseHeldTasks() }

  func stopWorker() async {
    guard stopped.withLock({ let wasStopped = $0; $0 = true; return !wasStopped }) else { return }
    await worker.quiesce()
    worker.release()
    await drain()
  }

  func close() async throws {
    await stopWorker()
    try database.reader.close()
    try await space.close()
  }
}

extension Space {
  func addMachineTestKey(_ machine: String) async throws -> String {
    let record = try await self.machine(.init(rawValue: machine))!
    let pubkey = Curve25519.Signing.PrivateKey().pubkeyLabel
    _ = try await addKey(pubkey, account: record.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    return pubkey
  }
}

/// A drain includes loose emitted jobs as well as cell lanes; protocol frames alone only establish durability.
private final class MachineCellTestScheduler: Scheduler {
  private struct State {
    var pending = 0
    var holdNext = false
    var held: [UnownedJob] = []
    var waiters: [AsyncStream<Void>.Continuation] = []
  }

  private let instant = Mutex(Instant(milliseconds: 1_800_000_000_000))
  var now: Instant { instant.withLock { $0 } }
  func advance(by milliseconds: Int64) { instant.withLock { $0 = $0 + .milliseconds(milliseconds) } }
  private let queue = DispatchQueue(label: "machine-cell-test")
  private let state = Mutex(State())

  func schedule(_ lane: Lane) {
    submit { if lane.run(limit: 32, pick: { _ in 0 }) { self.schedule(lane) } }
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let held = state.withLock { state in
      guard state.holdNext else { return false }
      state.holdNext = false
      state.held.append(job)
      return true
    }
    if !held { submit { job.runSynchronously(on: self.asUnownedTaskExecutor()) } }
  }

  func holdNextTask() {
    state.withLock { state in
      precondition(!state.holdNext)
      state.holdNext = true
    }
  }

  func stopHoldingNextTask() { state.withLock { $0.holdNext = false } }

  var heldTaskCount: Int { state.withLock { $0.held.count } }

  func releaseHeldTasks() {
    let jobs = state.withLock { state in
      defer { state.held.removeAll() }
      return state.held
    }
    for job in jobs { submit { job.runSynchronously(on: self.asUnownedTaskExecutor()) } }
  }

  func post(_ event: @escaping @Sendable () -> Void) { submit(event) }

  // These tests drive wake explicitly; no timer advances the fixed virtual time.
  func at(_: Instant, _: @escaping @Sendable () -> Void) {}

  private func submit(_ work: @escaping @Sendable () -> Void) {
    state.withLock { $0.pending += 1 }
    queue.async {
      work()
      let finished = self.state.withLock { state -> [AsyncStream<Void>.Continuation] in
        state.pending -= 1
        guard state.pending == 0 else { return [] }
        defer { state.waiters.removeAll() }
        return state.waiters
      }
      for waiter in finished { waiter.finish() }
    }
  }

  func drain() async {
    let done = AsyncStream<Void>.makeStream()
    let idle = state.withLock { state in
      guard state.pending > 0 else { return true }
      state.waiters.append(done.continuation)
      return false
    }
    if idle { done.continuation.finish() }
    for await _ in done.stream {}
  }
}
