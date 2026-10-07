import ClaudeStream
import Dependencies
import GRDB
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Logging
import SessionDomain
import SpaceCore
import Synchronization

public struct SessionService: Sendable {
  let livenessTracker = LivenessTracker()
  let registry: SessionRegistry
  let sessions: SessionStore
  let archiveGrace: Duration
  private let archives = ArchiveCoordinator()
  private let log: Logger

  public init(sessions: SessionStore, loopConfig: LoopConfig) async {
    await self.init(sessions: sessions, loopConfig: loopConfig) { SessionRepo(sessions: sessions, id: $0) }
  }

  init(sessions: SessionStore, loopConfig: LoopConfig, log: Logger = Logger(label: "wuhu.session-service"), makeRepo: @escaping @Sendable (SessionID) -> SessionRepo) async {
    self.sessions = sessions
    self.log = log
    archiveGrace = loopConfig.archiveGrace
    registry = SessionRegistry(
      makeRepo: makeRepo,
      loopConfig: loopConfig,
      liveness: livenessTracker,
    )
    await registry.activate()
  }

  public func start() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [livenessTracker] in
        await livenessTracker.drain()
      }
      group.addTask { [registry] in
        let (parking, continuation) = AsyncStream<Void>.makeStream()
        for await _ in parking {}
        continuation.finish()
        await registry.stop()
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
        do {
          try await wake(id)
        } catch {
          guard !Task.isCancelled else { return }
          await failSession(id, error: error, phase: "boot wake")
        }
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
                let succeeded = await wakeWithRetry(session)
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

  private func wakeWithRetry(_ id: SessionID) async -> Bool {
    @Dependency(\.continuousClock) var clock
    for attempt in 0 ... 3 {
      do {
        try await wake(id)
        return true
      } catch {
        guard !Task.isCancelled else { return false }
        if case SessionStoreError.unknownSession = error { return false }
        let transient: Bool
        if let database = error as? DatabaseError {
          transient = database.resultCode == .SQLITE_BUSY || database.resultCode == .SQLITE_LOCKED
        } else {
          transient = error is UnfulfilledError
        }
        guard transient, attempt < 3 else {
          await failSession(id, error: error, phase: "work signal wake")
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
    await registry.discard(id)
    do {
      try await sessions.markErrored(id, message: "\(phase) failed: \(error)")
    } catch {
      log.error("could not mark session errored", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
    }
  }

  func send(action: SessionActor.ExternalAction, to sessionID: SessionID) {
    Task { [registry] in
      await registry.post(action, to: sessionID)
    }
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

  // The executor gate: a session left over from the contractor executor is
  // never materialized, so every verb that can lazily create a SessionActor
  // checks the discriminator first and acts on the store directly instead.
  // Input still lands in its queue; nothing consumes it. Restarting it onto a
  // live executor is the way back.
  private func contractorRecord(_ sessionID: SessionID) async throws -> SessionRecord? {
    let record = try await sessions.record(sessionID)
    guard case .contractor = record.executor else { return nil }
    return record
  }

  public func wake(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { return }
    let record = try await sessions.record(sessionID)
    if case .contractor = record.executor { return }
    guard record.work != .errored else { return }
    try await retryingEviction {
      try await withCallback(of: Void.self) {
        send(action: .wake($0), to: sessionID)
      }
    }
  }

  public func enqueue(item: QueueInput, to sessionID: SessionID) async throws -> Int {
    if sessions.isReservedForArchive(sessionID) {
      return try await sessions.enqueue(sessionID, input: item)
    }
    if try await contractorRecord(sessionID) != nil {
      return try await sessions.enqueue(sessionID, input: item)
    }
    return try await retryingEviction {
      try await withCallback(of: Int.self) {
        send(action: .enqueue(item, $0), to: sessionID)
      }
    }
  }

  public func interrupt(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    if try await contractorRecord(sessionID) != nil {
      try await sessions.markInterrupted(sessionID)
      return
    }
    try await retryingEviction {
      try await withCallback(of: Void.self) {
        send(action: .interrupt($0), to: sessionID)
      }
    }
  }

  public func resume(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    do {
      if try await contractorRecord(sessionID) != nil {
        try await sessions.markResumed(sessionID)
        return
      }
      try await retryingEviction {
        try await withCallback(of: Void.self) {
          send(action: .resume($0), to: sessionID)
        }
      }
    } catch where error is DecodingError || error is ExecutorSpecError || (error as? CocoaError)?.code == .formatting {
      await registry.discard(sessionID)
      throw SessionError.unreadableData(sessionID)
    }
  }

  public func archive(_ sessionID: SessionID, force: Bool = false) async throws {
    try await archives.run { try await archiveSubtree(sessionID, force: force) }
  }

  private func archiveSubtree(_ sessionID: SessionID, force: Bool) async throws {
    var subtree = try await sessions.archiveSubtree(sessionID)
    let reservation = UUID()
    var prepared: [SessionID] = []
    var busy: [ArchiveBusySession] = []
    do {
      var checked: Set<SessionID> = []
      while true {
        for record in subtree where !checked.contains(record.id) {
          var settled = try await prepareArchive(record.id, reservation: reservation)
          if !settled, force {
            try await interrupt(record.id)
            settled = try await prepareArchive(record.id, reservation: reservation)
          }
          checked.insert(record.id)
          if settled {
            prepared.append(record.id)
            try await sessions.reserveForArchive(record.id, token: reservation)
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
        if case .contractor = record.executor {
          if case .live = record.lifecycle { _ = try await sessions.archive(record.id, grace: archiveGrace) }
        } else {
          try await retryingEviction {
            try await withCallback(of: Void.self) { send(action: .archive(reservation, $0), to: record.id) }
          }
        }
      }
    } catch {
      await releaseArchive(prepared, reservation: reservation)
      throw error
    }
    await releaseArchive(prepared, reservation: reservation)
  }

  private func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool {
    if try await contractorRecord(id) != nil { return true }
    return try await retryingEviction {
      try await withCallback(of: Bool.self) { send(action: .prepareArchive(reservation, $0), to: id) }
    }
  }

  private func releaseArchive(_ ids: [SessionID], reservation: UUID) async {
    for id in ids {
      sessions.releaseArchiveReservation(id, token: reservation)
      guard (try? await contractorRecord(id)) == nil else { continue }
      _ = try? await withCallback(of: Void.self) { send(action: .releaseArchive(reservation, $0), to: id) }
    }
  }

  public func restart(
    _ sessionID: SessionID,
    executor: SessionExecutor?,
    note: String?,
  ) async throws -> SessionRestart {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    if try await contractorRecord(sessionID) != nil {
      return try await sessions.restart(sessionID, executor: executor, note: note)
    }
    return try await retryingEviction {
      try await withCallback(of: SessionRestart.self) {
        send(action: .restart(executor, note, $0), to: sessionID)
      }
    }
  }

  // A hook reaches only a loaded session and only its current activation: a
  // late request from a process already ended hands nothing over.
  public func claudeCodeHook(_ sessionID: SessionID, activation: UUID, body: JSONValue) async -> JSONValue {
    guard let hook = ClaudeCodeHook(body: body) else { return [:] }
    guard let session = await registry.existing(sessionID) else { return hook.reply(handingOver: nil) }
    return await session.claudeCodeHook(hook, activation: activation)
  }

  public func claudeCodeContextTokens(_ sessionID: SessionID) async -> Int? {
    await registry.existing(sessionID)?.claudeCodeContextTokens
  }

  public func unarchive(_ sessionID: SessionID) async throws {
    guard !sessions.isReservedForArchive(sessionID) else { throw SessionError.archiveInProgress }
    if try await contractorRecord(sessionID) != nil {
      try await sessions.unarchive(sessionID)
      return
    }
    try await retryingEviction {
      try await withCallback(of: Void.self) {
        send(action: .unarchive($0), to: sessionID)
      }
    }
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

private actor ArchiveCoordinator {
  private var active = false
  private var waiting: [Callback<Void>] = []

  func run(_ operation: @Sendable () async throws -> Void) async throws {
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
    try await operation()
  }
}

private final class PendingWakes: Sendable {
  let state = Mutex<[SessionID: Bool]>([:])
}
