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
import enum SessionDomain.TranscriptItem
import protocol SessionTools.HandlerExecutionClient
import struct SessionTools.ScriptHandlerInvocation
import struct SessionTools.ScriptHandlerResult
import struct SessionTools.Spawned
import struct SessionTools.SpawnOrder
import struct SpaceCore.SessionRestart
import struct SpaceCore.SessionStore
import struct WorkerOwner.ExecutionWorkerActivity
import struct WorkerOwner.RemoteHandlerExecution
import struct WorkerOwner.RemoteSessionExecution
import struct WorkerOwner.WorkerRuntimeOwner
import struct WorkerProtocol.WorkerProtocolError

actor LazyExecutionWorker: SessionExecutionClient, HandlerExecutionClient {
  typealias Starter = @Sendable (@escaping @Sendable (ExecutionWorkerActivity) async throws -> Void, @escaping @Sendable () async -> Void) async throws -> WorkerConnection
  private let startConnection: Starter
  private let owner: any ExecutionOwnerClient
  private var incarnation: UUID?
  private var recoveryBlocked: Set<SessionID> = []
  private var activePasses: [SessionID: Set<UUID>] = [:]
  private var connection: WorkerConnection?
  private var starting: Task<WorkerConnection, any Error>?
  private var retirement: Task<Void, Never>?
  private var stopping: Task<Void, Never>?
  private var stopped = false
  private let sessions: SessionStore
  private var preparation: Task<Void, any Error>?
  private let log = Logger(label: "wuhu.execution-worker")
  var processID: Int32? { connection?.processID }
  var activeSessions: Set<SessionID> { Set(activePasses.keys) }

  init(executable: String, sessions: SessionStore, owner: any ExecutionOwnerClient, spawn: @escaping @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned, runtime: WorkerRuntimeOwner? = nil, machines: Bool = false, startConnection: Starter? = nil) {
    self.sessions = sessions; self.owner = owner
    self.startConnection = startConnection ?? { activity, exited in
      try await WorkerConnection.start(executable: executable, owner: owner, spawn: spawn, runtime: runtime, machines: machines, activity: activity, exited: exited)
    }
  }

  func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    let connection = try await connect()
    return try await RemoteHandlerExecution(client: connection.client).executeHandler(invocation)
  }

  private func remote() async throws -> RemoteSessionExecution {
    try await prepare()
    if let retirement { await retirement.value }
    return try await RemoteSessionExecution(client: connect().client)
  }

  private func connect() async throws -> WorkerConnection {
    guard !stopped else { throw SessionExecutionRetired() }
    if let connection { return connection }
    let id: UUID
    let start: Task<WorkerConnection, any Error>
    if let starting, let incarnation { id = incarnation; start = starting }
    else {
      id = UUID()
      incarnation = id
      start = Task {
        try await startConnection({ activity in
          try await self.activity(activity, incarnation: id)
        }, { await self.exited(id) })
      }
      starting = start
    }
    do {
      let connection = try await start.value
      guard !stopped, incarnation == id else {
        await connection.stop()
        throw SessionExecutionRetired()
      }
      self.connection = connection
      starting = nil
      return connection
    } catch {
      if incarnation == id { starting = nil; incarnation = nil }
      if let error = error as? WorkerProtocolError, error.code == .unavailable { throw SessionExecutionRetired() }
      throw error
    }
  }

  private func activity(_ activity: ExecutionWorkerActivity, incarnation: UUID) async throws {
    guard self.incarnation == incarnation else { throw SessionExecutionRetired() }
    if activity.active {
      activePasses[activity.session, default: []].insert(activity.pass)
      try await sessions.setWorkerActivity(activity.session, incarnation: incarnation, active: true)
    } else {
      activePasses[activity.session]?.remove(activity.pass)
      guard activePasses[activity.session]?.isEmpty == true else { return }
      activePasses[activity.session] = nil
      try await sessions.setWorkerActivity(activity.session, incarnation: incarnation, active: false)
    }
  }

  private func prepare() async throws {
    if let preparation { return try await preparation.value }
    let task = Task {
      let lost = try await sessions.recordWorkerLoss()
      await self.recoverLost(lost)
    }
    preparation = task
    try await task.value
  }

  private func exited(_ id: UUID) async {
    guard !stopped, incarnation == id else { return }
    let admitted = connection != nil || !activePasses.isEmpty
    connection = nil
    starting = nil
    incarnation = nil
    activePasses = [:]
    guard admitted else { return }
    let previous = retirement
    let recoveryID = UUID()
    let retirement = Task {
      await previous?.value
      await self.recover(id)
      self.finishRecovery(recoveryID)
    }
    recoveryIncarnation = recoveryID
    self.retirement = retirement
  }

  private var recoveryIncarnation: UUID?

  private func finishRecovery(_ id: UUID) {
    if recoveryIncarnation == id { retirement = nil; recoveryIncarnation = nil }
  }

  private func recover(_ incarnation: UUID) async {
    guard !stopped else { return }
    do {
      let lost = try await sessions.recordWorkerLoss(incarnation: incarnation)
      await recoverLost(lost)
      let pending = try await sessions.bootSessions { [log] id, error in
        log.error("worker recovery eligibility failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
      }
      for id in pending {
        guard !stopped else { return }
        do {
          let record = try await owner.record(id)
          guard !record.executor.isRemoved, record.work != .errored else { continue }
          if try await sessions.workerCrashFenced(id) {
            try await owner.markErrored(id, message: ExecutionWorkerCrashLoop(session: id).description)
            continue
          }
          guard !recoveryBlocked.contains(id) else { continue }
          try await retryRecovery {
            guard !self.recoveryBlocked.contains(id), try await self.owner.record(id).work != .errored else { return }
            let connection = try await self.connect()
            do { try await RemoteSessionExecution(client: connection.client).wake(id) }
            catch let error as WorkerProtocolError where error.code == .unavailable {
              await connection.stop()
              let lost = try await self.sessions.recordWorkerLoss()
              await self.recoverLost(lost)
              throw SessionExecutionRetired()
            }
          }
        } catch {
          log.error("execution worker session recovery failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
        }
      }
    } catch {
      log.error("execution worker crash recovery failed", metadata: ["error": "\(error)"])
    }
  }

  private func retryRecovery<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
    @Dependency(\.continuousClock) var clock
    for attempt in 0 ..< 3 {
      guard !stopped else { throw SessionExecutionRetired() }
      do { return try await operation() }
      catch {
        guard attempt < 2, !stopped else { throw error }
        try await clock.sleep(for: .milliseconds(100 * (attempt + 1)))
      }
    }
    preconditionFailure("unreachable")
  }

  private func recoverLost(_ lost: [SessionID: Bool]) async {
    recoveryBlocked.formUnion(lost.keys)
    for (id, fenced) in lost {
      do {
        try await retryRecovery { try await self.recoverInterruptedTools(id) }
        recoveryBlocked.remove(id)
      } catch {
        log.error("execution worker lost session recovery failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
        do {
          try await retryRecovery { try await self.owner.markErrored(id, message: "executionWorkerRecoveryFailed: interrupted tool results could not be committed; automatic execution is blocked") }
        } catch {
          log.error("execution worker recovery fencing failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
        }
      }
      if fenced {
        do { try await retryRecovery { try await self.owner.markErrored(id, message: ExecutionWorkerCrashLoop(session: id).description) } }
        catch { log.error("execution worker crash fencing failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"]) }
      }
    }
  }

  private func recoverInterruptedTools(_ id: SessionID) async throws {
    let hydration = try await owner.hydrate(id)
    var transcript = switch hydration.transcript { case let .kernel(value): value }
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    let items = transcript.pendingToolCallIDs.map { call in
      TranscriptItem.toolResult(.init(id: uuid(), timestamp: date.now, provenance: .toolCall(call), payload: .failure(.init(message: "Execution worker crashed during tool execution. Its effects are unknown; it will not be retried automatically.", code: "executionWorkerRestart"))))
    }
    guard !items.isEmpty else { return }
    transcript.items.append(contentsOf: items)
    try await owner.append(id, items: items, transcript: transcript, completingCompactRequest: nil)
  }

  func wake(_ id: SessionID) async throws {
    try await prepare()
    if try await sessions.workerCrashFenced(id) {
      await recoverLost([id: true])
      return
    }
    if let retirement { await retirement.value }
    guard !recoveryBlocked.contains(id) else { throw SessionExecutionRetired() }
    let connection = try await connect()
    do {
      try await RemoteSessionExecution(client: connection.client).wake(id)
    } catch let error as WorkerProtocolError where error.code == .unavailable {
      await connection.stop()
      if let retirement { await retirement.value }
      throw SessionExecutionRetired()
    }
  }

  func enqueue(_ item: QueueInput, to id: SessionID) async throws -> Int {
    try await remote().enqueue(item, to: id)
  }

  func interrupt(_ id: SessionID) async throws -> Void {
    try await remote().interrupt(id)
  }

  func resume(_ id: SessionID) async throws -> Void {
    try await remote().resume(id)
  }

  func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool {
    try await remote().prepareArchive(id, reservation: reservation)
  }

  func releaseArchive(_ id: SessionID, reservation: UUID) async throws -> Void {
    try await remote().releaseArchive(id, reservation: reservation)
  }

  func archive(_ id: SessionID, reservation: UUID) async throws -> Void {
    try await remote().archive(id, reservation: reservation)
  }

  func unarchive(_ id: SessionID) async throws -> Void {
    try await remote().unarchive(id)
  }

  func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    let result = try await remote().restart(id, executor: executor, note: note, modelRoute: modelRoute)
    recoveryBlocked.remove(id)
    return result
  }

  func discard(_ id: SessionID) async {
    guard let connection else { return }
    await RemoteSessionExecution(client: connection.client).discard(id)
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
    let connection = self.connection
    self.connection = nil
    let starting = self.starting
    self.starting = nil
    let retirement = self.retirement
    let preparation = self.preparation
    let stopping = Task {
      starting?.cancel()
      if let starting, case let .success(started) = await starting.result { await started.stop() }
      if let connection { await connection.stop() }
      await retirement?.value
      if let preparation { _ = await preparation.result }
    }
    self.stopping = stopping
    await stopping.value
  }
}
