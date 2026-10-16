#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import protocol ExecutionOwner.ExecutionOwnerClient
import Logging
import protocol LoopCore.SessionExecutionClient
import struct LoopCore.SessionExecutionRetired
import enum SessionDomain.QueueInput
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import struct SessionDomain.ToolCallID
import protocol SessionTools.HandlerExecutionClient
import struct SessionTools.ScriptHandlerInvocation
import struct SessionTools.ScriptHandlerResult
import struct SessionTools.Spawned
import struct SessionTools.SpawnOrder
import struct SpaceCore.SessionRestart
import struct SpaceCore.SessionStore
import struct WorkerOwner.WorkerRuntimeOwner

actor LazyExecutionWorker: SessionExecutionClient, HandlerExecutionClient {
  typealias Starter = ExecutionWorkerGeneration.Starter
  private struct Generation {
    let worker: ExecutionWorkerGeneration
    var handlers = 0
  }

  private let makeGeneration: @Sendable (UUID, Bool) -> ExecutionWorkerGeneration
  private let startupExcludedSessions: Set<SessionID>
  private let scripts: WorkerScriptDirectory
  private var current: UUID
  private var generations: [UUID: Generation]
  private var assignments: [SessionID: UUID] = [:]
  private var handoffs: [UUID: Task<Void, Never>] = [:]
  private var sessionHandoffs: [SessionID: UUID] = [:]
  private var scriptChanges: Task<Void, Never>?
  private var stopped = false
  private var execPaused = false
  private var stopping: Task<Void, Never>?
  private let log = Logger(label: "wuhu.execution-directory")

  init(executable: String, sessions: SessionStore, owner: any ExecutionOwnerClient, spawn: @escaping @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned, runtime: WorkerRuntimeOwner? = nil, machines: Bool = false, persistence: ExecutionWorkerPersistence? = nil, startConnection: Starter? = nil, credentialFence: ExecutionWorkerCredentialFence? = nil, startupExcludedIncarnations: Set<UUID> = [], startupExcludedSessions: Set<SessionID> = [], adoptingExec: ExecSpaceRecord? = nil) {
    self.startupExcludedSessions = startupExcludedSessions
    let scripts = WorkerScriptDirectory()
    self.scripts = scripts
    let make: @Sendable (UUID, Bool) -> ExecutionWorkerGeneration = { generation, recoverStartupLoss in
      let inherited = recoverStartupLoss ? adoptingExec?.worker : nil
      return ExecutionWorkerGeneration(executable: executable, sessions: sessions, owner: owner, spawn: spawn, startConnection: { incarnation, activity, exited in
        var runtimeOwner = runtime
        runtimeOwner?.scriptStarted = { session, script in
          guard !startupExcludedSessions.contains(session) else { throw ExecutionWorkerFencePending(session: session) }
          try await sessions.registerWorkerScript(script, session: session, incarnation: incarnation)
          do { try await scripts.started(script, session: session, generation: generation) }
          catch { try? await sessions.releaseWorkerScript(script, session: session, incarnation: incarnation); throw error }
        }
        runtimeOwner?.scriptEnded = { session, script in
          try? await sessions.releaseWorkerScript(script, session: session, incarnation: incarnation)
          await scripts.ended(script, session: session, generation: generation)
        }
        runtimeOwner?.stopScript = { session, script in try await scripts.stop(script, session: session) }
        let lost: @Sendable () async -> Void = {
          await scripts.lost(generation)
          await exited()
        }
        if let startConnection { return try await startConnection(incarnation, activity, lost) }
        if let record = inherited, record.incarnation == incarnation {
          return try await WorkerConnection.adoptExec(record, configDirectory: persistence?.configDirectory, owner: owner, spawn: spawn, runtime: runtimeOwner, credentialFence: credentialFence, activity: activity, exited: lost)
        }
        return try await WorkerConnection.start(executable: executable, owner: owner, spawn: spawn, runtime: runtimeOwner, machines: machines, persistence: persistence, incarnation: incarnation, credentialFence: credentialFence, activity: activity, exited: lost)
      }, recoverStartupLoss: recoverStartupLoss, startupExcludedIncarnations: startupExcludedIncarnations, adoptingExec: inherited)
    }
    makeGeneration = make
    let id = UUID()
    current = id
    generations = [id: Generation(worker: make(id, true))]
    assignments = Dictionary(uniqueKeysWithValues: (adoptingExec?.assignments ?? []).map { (SessionID(rawValue: $0), id) })
  }

  var processID: Int32? { get async { await generations[current]?.worker.processID } }
  var generationCount: Int { generations.count }
  func runningScripts(_ id: SessionID) async -> [String] { await scripts.scripts(for: id) }
  var activeSessions: Set<SessionID> {
    get async {
      var result: Set<SessionID> = []
      for generation in generations.values { result.formUnion(await generation.worker.activeSessions) }
      return result
    }
  }

  private func selected(_ id: SessionID? = nil) async throws -> (UUID, ExecutionWorkerGeneration) {
    guard !stopped, !execPaused else { throw SessionExecutionRetired() }
    if scriptChanges == nil {
      scriptChanges = Task {
        for await _ in scripts.changes {
          for generation in await scripts.takeChanges() { await retireIfReady(generation) }
        }
      }
    }
    let selected: UUID
    if let id {
      if startupExcludedSessions.contains(id) { throw ExecutionWorkerFencePending(session: id) }
      selected = assignments[id] ?? current
      assignments[id] = selected
    } else {
      selected = current
      generations[selected]!.handlers += 1
    }
    let worker = generations[selected]!.worker
    await worker.configureRecovery { id in await self.admitRecovery(id, generation: selected) }
    await scripts.bind(selected) { script, session in try await worker.stopScript(script, session: session) }
    if let id { try await worker.assign(id) }
    return (selected, worker)
  }

  private func admitRecovery(_ id: SessionID, generation: UUID) -> Bool {
    guard !stopped, !startupExcludedSessions.contains(id), generation == current, assignments[id] == nil || assignments[id] == generation else { return false }
    assignments[id] = generation
    return true
  }

  private func perform<Value: Sendable>(_ id: SessionID, _ body: (ExecutionWorkerGeneration) async throws -> Value) async throws -> Value {
    let (generation, worker) = try await selected(id)
    do { return try await body(worker) }
    catch is SessionExecutionRetired {
      guard generation != current, let token = sessionHandoffs[id], let handoff = handoffs[token] else { throw SessionExecutionRetired() }
      await handoff.value
      guard assignments[id] != generation else { throw SessionExecutionRetired() }
      let (_, next) = try await selected(id)
      return try await body(next)
    }
  }

  func prepareExec() async throws -> ExecSpaceExport {
    guard !stopped, !execPaused, handoffs.isEmpty, generations.count == 1,
          generations.values.allSatisfy({ $0.handlers == 0 }) else { throw AdminExecError.refused("generationBusy") }
    execPaused = true
    do {
      guard !(await scripts.contains(current)) else { throw AdminExecError.refused("generationBusy") }
      let exported = try await generations[current]!.worker.prepareExec()
      return .init(record: .init(worker: exported?.record, assignments: assignments.keys.map(\.rawValue).sorted()), worker: exported)
    } catch { execPaused = false; throw error }
  }

  func rollbackExec() async throws {
    try await generations[current]!.worker.rollbackExec()
    execPaused = false
  }

  func reconcileExec() async throws { try await generations[current]!.worker.reconcileExec() }

  func probeExec() async throws { try await generations[current]?.worker.probeExec() }

  func replaceGeneration() async throws {
    guard !stopped, !execPaused else { throw SessionExecutionRetired() }
    let old = current
    let worker = generations[old]!.worker
    try await worker.requireHandoff()
    guard !stopped, old == current else { throw SessionExecutionRetired() }
    let next = UUID()
    generations[next] = Generation(worker: makeGeneration(next, false))
    current = next
    for (session, generation) in assignments where generation == old {
      let token = UUID()
      sessionHandoffs[session] = token
      handoffs[token] = Task {
        do {
          try await self.yieldAssignment(session, worker: worker)
          try await self.released(session, generation: old)
        } catch {
          self.log.error("execution assignment handoff failed", metadata: ["session": "\(session.rawValue)", "error": "\(error)"])
        }
        self.handoffs[token] = nil
        if self.sessionHandoffs[session] == token { self.sessionHandoffs[session] = nil }
      }
    }
    await retireIfReady(old)
  }

  private func yieldAssignment(_ id: SessionID, worker: ExecutionWorkerGeneration) async throws {
    try await retryHandoff(id) { try await worker.yieldAssignment(id) }
  }

  private func retryHandoff(_ id: SessionID, _ operation: () async throws -> Void) async throws {
    @Dependency(\.continuousClock) var clock
    var reported = false
    while !stopped, !Task.isCancelled {
      do { try await operation(); return }
      catch {
        guard !stopped, !Task.isCancelled else { throw error }
        if !reported {
          log.warning("execution handoff waiting for owner recovery", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
          reported = true
        }
        try await clock.sleep(for: .milliseconds(100))
      }
    }
    throw SessionExecutionRetired()
  }

  private func released(_ id: SessionID, generation: UUID) async throws {
    guard !stopped, assignments[id] == generation else { return }
    assignments[id] = nil
    try await retryHandoff(id) { try await self.perform(id) { try await $0.wake(id) } }
    await retireIfReady(generation)
  }

  private func retireIfReady(_ id: UUID) async {
    guard id != current, !assignments.values.contains(id), let generation = generations[id], generation.handlers == 0, await !scripts.contains(id) else { return }
    generations[id] = nil
    await generation.worker.shutdown()
    await scripts.remove(id)
  }

  func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    if startupExcludedSessions.contains(invocation.session) { throw ExecutionWorkerFencePending(session: invocation.session) }
    let (id, worker) = try await selected()
    do {
      let result = try await worker.executeHandler(invocation)
      return ScriptHandlerResult(stateJSON: result.stateJSON, wakes: result.wakes, acknowledge: {
        await result.acknowledge()
        await self.handlerConsumed(id)
      })
    } catch {
      await handlerConsumed(id)
      throw error
    }
  }

  private func handlerConsumed(_ id: UUID) async {
    generations[id]?.handlers -= 1
    await retireIfReady(id)
  }

  func wake(_ id: SessionID) async throws { try await perform(id) { try await $0.wake(id) } }
  func enqueue(_ item: QueueInput, to id: SessionID) async throws -> Int { try await perform(id) { try await $0.enqueue(item, to: id) } }
  func interrupt(_ id: SessionID) async throws { try await perform(id) { try await $0.interrupt(id) } }
  func resume(_ id: SessionID) async throws { try await perform(id) { try await $0.resume(id) } }
  func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool { try await perform(id) { try await $0.prepareArchive(id, reservation: reservation) } }
  func releaseArchive(_ id: SessionID, reservation: UUID) async throws { try await perform(id) { try await $0.releaseArchive(id, reservation: reservation) } }
  func archive(_ id: SessionID, reservation: UUID) async throws {
    try await perform(id) { try await $0.archive(id, reservation: reservation) }
    try await scripts.stopAll(id)
  }

  func unarchive(_ id: SessionID) async throws { try await perform(id) { try await $0.unarchive(id) } }
  func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    try await perform(id) { try await $0.restart(id, executor: executor, note: note, modelRoute: modelRoute) }
  }

  func discard(_ id: SessionID) async {
    guard let generation = assignments[id], let worker = generations[generation]?.worker else { return }
    await worker.discard(id)
  }

  func drain() async {
    let (parking, continuation) = AsyncStream<Void>.makeStream()
    for await _ in parking {}
    continuation.finish()
    await shutdown()
  }

  func shutdown() async {
    if let stopping { await stopping.value; return }
    stopped = true
    let generations = Array(generations.values)
    self.generations.removeAll()
    let handoffs = Array(handoffs.values)
    self.handoffs.removeAll()
    sessionHandoffs.removeAll()
    scriptChanges?.cancel()
    let watcher = scriptChanges
    scriptChanges = nil
    let stopping = Task {
      for handoff in handoffs { handoff.cancel() }
      for generation in generations { await generation.worker.shutdown() }
      for handoff in handoffs { await handoff.value }
      await scripts.shutdown()
      await watcher?.value
    }
    self.stopping = stopping
    await stopping.value
  }
}
