import Dependencies
import GRDB
import protocol MainHub.Worker
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Logging
import SessionDomain
import func SessionTools.scriptHandle
import SpaceCore
import Synchronization

public final class SessionService: Sendable {
  private let worker: any Worker
  private let beforeArchive: @Sendable (SessionID) async throws -> Void
  private let archived: @Sendable (SessionID) async -> Void
  let sessions: SessionStore
  let archiveGrace: Duration
  private let reminders: SessionReminders
  private let lifecycle = LifecycleCoordinator()
  private let runningWork: @Sendable (SessionID) async throws -> [String]
  private let log: Logger

  public convenience init(sessions: SessionStore, worker: any Worker, archiveGrace: Duration = .seconds(24 * 3600), runningWork: @escaping @Sendable (SessionID) async throws -> [String] = { _ in [] }, archived: @escaping @Sendable (SessionID) async -> Void = { _ in }) {
    self.init(sessions: sessions, worker: worker, archiveGrace: archiveGrace, runningWork: runningWork, archived: archived, log: Logger(label: "wuhu.session-service"))
  }

  init(sessions: SessionStore, worker: any Worker, archiveGrace: Duration, runningWork: @escaping @Sendable (SessionID) async throws -> [String] = { _ in [] }, archived: @escaping @Sendable (SessionID) async -> Void = { _ in }, beforeArchive: @escaping @Sendable (SessionID) async throws -> Void = { _ in }, log: Logger) {
    self.sessions = sessions
    self.runningWork = runningWork
    self.worker = worker
    self.archived = archived
    self.beforeArchive = beforeArchive
    self.archiveGrace = archiveGrace
    self.log = log
    reminders = SessionReminders(sessions: sessions, execution: worker)
  }

  public func scheduleWake(_ id: SessionID, at due: Date?) async {
    await reminders.schedule(id, at: due)
  }

  public func shutdown() async {
    await reminders.shutdown()
    await worker.shutdown()
  }

  public func start() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [worker] in
        await worker.drain()
      }
      group.addTask {
        let (parking, continuation) = AsyncStream<Void>.makeStream()
        for await _ in parking {}
        continuation.finish()
        await self.shutdown()
      }
      let signals = sessions.workSignals()
      let boot: [SessionID]
      let failures = Mutex<[(SessionID, any Error)]>([])
      do {
        boot = try await sessions.bootSessions { id, error in
          failures.withLock { $0.append((id, error)) }
        }
      } catch {
        guard !Task.isCancelled else { return }
        log.error("boot session scan failed", metadata: ["error": "\(error)"])
        boot = []
      }
      for (id, error) in failures.withLock({ $0 }) {
        guard !Task.isCancelled else { return }
        await failSession(id, error: error, phase: "boot eligibility")
      }
      for id in boot {
        guard !Task.isCancelled else { return }
        _ = await wakeWithRetry(id, phase: "boot wake")
      }
      group.addTask {
        let pending = PendingWakes()
        await withDiscardingTaskGroup { wakes in
          for await session in signals {
            guard !Task.isCancelled else { break }
            let admitted = pending.state.withLock { state in
              if state[session] != nil {
                state[session] = true
                return false
              }
              state[session] = false
              return true
            }
            guard admitted else { continue }
            wakes.addTask {
              while !Task.isCancelled {
                let succeeded = await self.wakeWithRetry(session)
                let repeatWake = pending.state.withLock { state in
                  if succeeded, state[session] == true {
                    state[session] = false
                    return true
                  }
                  state[session] = nil
                  return false
                }
                guard repeatWake else { return }
              }
            }
          }
          wakes.cancelAll()
        }
      }
      try await group.waitForAll()
    }
  }

  private func wakeWithRetry(_ id: SessionID, phase: String = "work signal wake") async -> Bool {
    @Dependency(\.continuousClock) var clock
    for attempt in 0 ... 3 {
      do {
        try await wake(id)
        return true
      } catch {
        guard !Task.isCancelled else { return false }
        if case SessionStoreError.unknownSession = error {
          if phase == "boot wake" { await failSession(id, error: error, phase: phase) }
          return false
        }
        let transient: Bool
        if let database = error as? DatabaseError {
          transient = database.resultCode == .SQLITE_BUSY || database.resultCode == .SQLITE_LOCKED
        } else {
          transient = error is UnfulfilledError
        }
        guard transient, attempt < 3 else {
          await failSession(id, error: error, phase: phase)
          return false
        }
        log.warning("session wake retry scheduled", metadata: ["session": "\(id.rawValue)", "error": "\(error)", "attempt": "\(attempt + 1)"])
        do {
          try await clock.sleep(for: .seconds(1 << attempt))
        } catch {
          return false
        }
      }
    }
    return false
  }

  private func failSession(_ id: SessionID, error: any Error, phase: String) async {
    log.error("\(phase) failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
    do {
      try await sessions.markErrored(id, message: error is ExecutorUnavailableError ? "executor no longer supported" : "\(phase) failed: \(error)")
    } catch {
      log.error("could not mark session errored", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
    }
    _ = try? await worker.revoke(id, policy: .cancel)
  }

  // UnfulfilledError is the retryable outcome of racing a retirement; one
  // retry lands because the verb path lazily rematerializes the session.
  private func retryingEviction<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch is UnfulfilledError {
      return try await body()
    }
  }

  private func inactiveExecutorRecord(_ sessionID: SessionID) async throws -> SessionRecord? {
    let record = try await sessions.record(sessionID)
    guard record.executor.isRemoved else { return nil }
    return record
  }

  public func wake(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { return }
    let record = try await sessions.record(sessionID)
    if case .claudeCode = record.executor {
      if record.work != .errored { try await sessions.markErrored(sessionID, message: ExecutorUnavailableError().description) }
      return
    }
    if case .contractor = record.executor { return }
    guard record.work != .errored else { return }
    do {
      try await retryingEviction { try await worker.deliver(sessionID, .wake) }
    } catch ExecutionHydrationError.reservedForArchive { return }
  }

  public func enqueue(item: QueueInput, to sessionID: SessionID) async throws -> Int {
    let position = try await sessions.enqueue(sessionID, input: item)
    if !sessions.isReservedForArchive(sessionID) {
      _ = await wakeWithRetry(sessionID)
    }
    return position
  }

  public func interrupt(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    if try await inactiveExecutorRecord(sessionID) != nil {
      if case .claudeCode = try await sessions.record(sessionID).executor { return }
      try await sessions.markInterrupted(sessionID)
      return
    }
    try await retryingEviction {
      try await worker.deliver(sessionID, .interrupt)
    }
    await reminders.schedule(sessionID, at: nil)
  }

  public func resume(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    do {
      if try await inactiveExecutorRecord(sessionID) != nil {
        try await sessions.markResumed(sessionID)
        return
      }
      try await retryingEviction {
        try await worker.deliver(sessionID, .resume)
      }
    } catch where error is DecodingError || error is ExecutorSpecError || (error as? CocoaError)?.code == .formatting {
      await failSession(sessionID, error: SessionError.unreadableData(sessionID), phase: "resume")
      throw SessionError.unreadableData(sessionID)
    }
  }

  public func archive(_ sessionID: SessionID, force: Bool = false) async throws {
    try await lifecycle.run { try await archiveSubtree(sessionID, force: force) }
  }

  private func archiveSubtree(_ sessionID: SessionID, force: Bool) async throws {
    var subtree = try await sessions.archiveSubtree(sessionID)
    let reservation = UUID()
    var prepared: [SessionID] = []
    var inactive: Set<SessionID> = []
    var busy: [ArchiveBusySession] = []
    do {
      var checked: Set<SessionID> = []
      while true {
        for record in subtree where !checked.contains(record.id) {
          let settled = try await prepareArchive(record.id)
          if !settled, force {
            try await interrupt(record.id)
          }
          checked.insert(record.id)
          if settled || force {
            prepared.append(record.id)
            if record.executor.isRemoved { inactive.insert(record.id) }
            try await sessions.reserveForArchive(record.id, token: reservation)
            if !settled { _ = try await retryingEviction { try await worker.revoke(record.id, policy: .cancel) } }
          } else {
            busy.append(ArchiveBusySession(id: record.id, title: record.title))
          }
        }
        subtree = try await sessions.archiveSubtree(sessionID)
        if subtree.allSatisfy({ checked.contains($0.id) }) { break }
      }
      guard busy.isEmpty else { throw SubtreeArchiveBusy(sessions: busy) }
      if force {
        for record in subtree { try await sessions.closeRequestsForArchive(record.id) }
      }
      for member in subtree {
        let record = try await sessions.record(member.id)
        if inactive.contains(record.id), !record.executor.isRemoved { throw SessionError.archiveReservationLost }
        if case .live = record.lifecycle {
          try await beforeArchive(record.id)
          _ = try await sessions.archive(record.id, grace: archiveGrace)
        }
        if !record.executor.isRemoved {
          try await worker.deliver(record.id, .archived)
          await archived(record.id)
        }
        await reminders.schedule(member.id, at: nil)
      }
    } catch {
      await releaseArchive(prepared, reservation: reservation)
      throw error
    }
    await releaseArchive(prepared, reservation: reservation)
  }

  private func prepareArchive(_ id: SessionID) async throws -> Bool {
    if try await inactiveExecutorRecord(id) != nil { return true }
    return try await retryingEviction {
      try await worker.revoke(id, policy: .whenSettled)
    }
  }

  private func releaseArchive(_ ids: [SessionID], reservation: UUID) async {
    for id in ids {
      sessions.releaseArchiveReservation(id, token: reservation)
      guard (try? await inactiveExecutorRecord(id)) == nil else { continue }
      if let record = try? await sessions.record(id), record.lifecycle == .live {
        try? await worker.deliver(id, .reload)
      }
    }
  }

  public func restart(
    _ sessionID: SessionID,
    executor: SessionExecutor?,
    note: String?,
    modelRoute: SessionModelRoute? = nil,
  ) async throws -> SessionRestart {
    try await lifecycle.run {
      try await restartSettled(sessionID, executor: executor, note: note, modelRoute: modelRoute)
    }
  }

  private func restartSettled(_ sessionID: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    if try await inactiveExecutorRecord(sessionID) != nil {
      let result = try await sessions.restart(sessionID, executor: executor, note: note, modelRoute: modelRoute)
      await reloadCommitted(sessionID)
      return result
    }
    guard try await sessions.record(sessionID).lifecycle == .live else {
      throw SessionStoreError.restartOfArchivedSession(sessionID.rawValue)
    }
    guard try await retryingEviction({ try await worker.revoke(sessionID, policy: .whenSettled) }) else {
      throw SessionStoreError.busyForRestart(sessionID.rawValue)
    }
    let result: SessionRestart
    do {
      let scripts = await worker.activity().scripts.filter { $0.value == sessionID }.keys.map { scriptHandle($0.rawValue) }.sorted()
      result = try await sessions.restart(sessionID, executor: executor, note: note, modelRoute: modelRoute, runningWork: scripts + (try await runningWork(sessionID)))
    } catch {
      await reloadCommitted(sessionID)
      throw error
    }
    await reloadCommitted(sessionID)
    await reminders.schedule(sessionID, at: nil)
    return result
  }

  private func reloadCommitted(_ id: SessionID) async {
    do {
      try await retryingEviction { try await worker.deliver(id, .reload) }
    } catch {
      switch error {
      case is CancellationError, is UnfulfilledError, SessionError.archiveInProgress, ExecutionHydrationError.reservedForArchive:
        log.warning("committed reload deferred", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
      default:
        await failSession(id, error: error, phase: "committed reload")
      }
    }
  }

  public func unarchive(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    if try await inactiveExecutorRecord(sessionID) != nil {
      try await sessions.unarchive(sessionID)
      if case .claudeCode = try await sessions.record(sessionID).executor {
        try await sessions.markErrored(sessionID, message: ExecutorUnavailableError().description)
      }
      return
    }
    guard case .archived = try await sessions.record(sessionID).lifecycle else { return }
    try await sessions.unarchive(sessionID)
    await reloadCommitted(sessionID)
  }
}

// A session's live work: each loop pass holds a token from wake to settle, so
// drain-on-shutdown waits for in-flight tool/inference/compaction work to
// reach a settle or park boundary. Verbs are quick actor hops and don't count.
final class LivenessTracker: Sendable {
  struct Token: Hashable {
    private let id = UUID()
  }

  private struct TrackerState {
    var active: Set<Token> = []
    var waiter: CheckedContinuation<Void, Never>?
  }

  private let state = Mutex(TrackerState())

  func start() -> Token {
    let token = Token()
    state.withLock { _ = $0.active.insert(token) }
    return token
  }

  func end(_ token: Token) {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.active.remove(token)
      guard state.active.isEmpty, let waiter = state.waiter else { return nil }
      state.waiter = nil
      return waiter
    }
    waiter?.resume()
  }

  // Parks until the surrounding task is cancelled, then waits for in-flight
  // work to end. Single caller by contract (the service's start()).
  func drain() async {
    let (parking, parkingContinuation) = AsyncStream<Void>.makeStream()
    for await _ in parking {}
    parkingContinuation.finish()

    await withCheckedContinuation { cont in
      let resumeNow = state.withLock { state -> Bool in
        precondition(state.waiter == nil, "LivenessTracker.drain has a single caller")
        if state.active.isEmpty { return true }
        state.waiter = cont
        return false
      }
      if resumeNow {
        cont.resume()
      }
    }
  }
}

private actor LifecycleCoordinator {
  private var active = false
  private var waiting: [Callback<Void>] = []

  func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
    if active {
      try await withCallback(of: Void.self) { waiting.append($0) }
    } else {
      active = true
    }
    defer {
      if waiting.isEmpty {
        active = false
      } else {
        waiting.removeFirst().resume(returning: ())
      }
    }
    try Task.checkCancellation()
    return try await operation()
  }
}

private final class PendingWakes: Sendable {
  let state = Mutex<[SessionID: Bool]>([:])
}
