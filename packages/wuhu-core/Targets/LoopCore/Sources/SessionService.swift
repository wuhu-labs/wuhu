import ClaudeStream
import Foundation
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

  public init(sessions: SessionStore, loopConfig: LoopConfig) async {
    await self.init(sessions: sessions, loopConfig: loopConfig) { SessionRepo(sessions: sessions, id: $0) }
  }

  init(sessions: SessionStore, loopConfig: LoopConfig, makeRepo: @escaping @Sendable (SessionID) -> SessionRepo) async {
    self.sessions = sessions
    archiveGrace = loopConfig.archiveGrace
    registry = SessionRegistry(
      makeRepo: makeRepo,
      loopConfig: loopConfig,
      liveness: livenessTracker,
    )
    await registry.activate()
  }

  public func start() async throws {
    let signals = sessions.workSignals()
    for id in try await sessions.bootSessions() {
      try await wake(id)
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        let log = Logger(label: "wuhu.session-service")
        for await session in signals {
          do {
            try await wake(session)
          } catch {
            guard !Task.isCancelled else { break }
            // A dropped signal is dropped work: put it back and try again.
            log.warning("wake failed for \(session.rawValue), re-signaling: \(error)")
            signals.repost(session)
          }
        }
      }
      group.addTask { [livenessTracker, registry] in
        await withTaskCancellationHandler {
          await livenessTracker.drain()
        } onCancel: {
          Task { [registry] in
            await registry.stop()
          }
        }
      }
      await group.waitForAll()
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
    guard try await contractorRecord(sessionID) == nil else { return }
    try await retryingEviction {
      try await withCallback(of: Void.self) {
        send(action: .wake($0), to: sessionID)
      }
    }
  }

  public func enqueue(item: QueueInput, to sessionID: SessionID) async throws -> Int {
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
    if try await contractorRecord(sessionID) != nil {
      try await sessions.markResumed(sessionID)
      return
    }
    try await retryingEviction {
      try await withCallback(of: Void.self) {
        send(action: .resume($0), to: sessionID)
      }
    }
  }

  public func archive(_ sessionID: SessionID) async throws {
    if let record = try await contractorRecord(sessionID) {
      if case .live = record.lifecycle {
        _ = try await sessions.archive(sessionID, grace: archiveGrace)
      }
      return
    }
    try await retryingEviction {
      try await withCallback(of: Void.self) {
        send(action: .archive($0), to: sessionID)
      }
    }
  }

  public func restart(
    _ sessionID: SessionID,
    executor: SessionExecutor?,
    note: String?,
  ) async throws -> SessionRestart {
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
