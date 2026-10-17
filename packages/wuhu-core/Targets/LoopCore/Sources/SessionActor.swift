import Dependencies
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore

actor SessionActor {
  enum Lifecycle: Hashable {
    case live
    case archived(graceExpiry: Date)
  }

  enum RunStatus {
    case healthy
    case interrupting(Callback<Void>)
    case interrupted
    case errored(String)

    var stopped: Bool {
      switch self {
      case .interrupted, .errored:
        return true
      case .healthy, .interrupting:
        return false
      }
    }
  }

  struct LiveState {
    let mountID: UUID
    var generation: Int
    var compactRequestClaim: CompactRequestClaim?
    var transcript: Transcript
    var queueHead: Int
    var queueTail: Int
    var sessionStatus: RunStatus
    var lastUpdatedByLoopAt: Date?
    let group: String
    let isTask: Bool
    var delegatedWake = false
    var parkWake: (at: Date, task: Task<Void, Never>)?
    var archiving = false
    var claimingCompactRequest = false
    var malformedMessages = 0
    var capacityFailures = 0
    var compactedForPayload = false

    var hasSettled: Bool {
      if sessionStatus.stopped {
        return true
      }
      guard !claimingCompactRequest, compactRequestClaim == nil, queueHead == queueTail else { return false }
      return !transcript.hasWork
    }
  }

  enum ExternalAction {
    case wake(Callback<Void>)
    case enqueue(QueueInput, Callback<Int>)
    case prepareArchive(UUID, Callback<Bool>)
    case releaseArchive(UUID, Callback<Void>)
    case archive(UUID, Callback<Void>)
    case unarchive(Callback<Void>)
    case interrupt(Callback<Void>)
    case resume(Callback<Void>)
    case restart(SessionExecutor?, String?, SessionModelRoute?, Callback<SessionRestart>)
  }

  nonisolated let id: SessionID
  let repo: SessionRepo
  let loopConfig: LoopConfig
  let liveness: LivenessTracker
  let beforeCompactRequest: @Sendable () async -> Void
  let afterLoop: @Sendable () async -> Void

  private nonisolated let inbox = Inbox<ExternalAction>()

  private var lifecycle: Lifecycle?
  var liveState: LiveState?
  private var lastCommandProcessedAt: Date?
  private var nudges: Inbox<Void>?
  let taskScope = TaskScope()
  private var handlerTask: Task<Void, Never>?
  private(set) var looperTask: Task<Void, Never>?
  var longRunningTask: (id: UUID, task: Task<Void, Never>)?
  var retryPause: Task<Void, any Error>?
  private var retired = false
  private var archiveReservation: UUID?

  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  @Dependency(\.continuousClock) var clock
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  init(id: SessionID, repo: SessionRepo, loopConfig: LoopConfig, liveness: LivenessTracker, beforeCompactRequest: @escaping @Sendable () async -> Void = {}, afterLoop: @escaping @Sendable () async -> Void = {}) {
    self.id = id
    self.repo = repo
    self.loopConfig = loopConfig
    self.liveness = liveness
    self.beforeCompactRequest = beforeCompactRequest
    self.afterLoop = afterLoop
  }

  func activate() {
    precondition(handlerTask == nil, "SessionActor activates once")
    guard !retired else { return }
    handlerTask = try? taskScope.run("session-handler") { await runHandler() }
  }

  var live: LiveState {
    get throws {
      try Task.checkCancellation()
      guard let liveState else { throw CancellationError() }
      return liveState
    }
  }

  func modify(_ body: (inout LiveState) -> Void) throws {
    try Task.checkCancellation()
    guard liveState != nil else { throw CancellationError() }
    body(&liveState!)
  }

  nonisolated func post(_ action: ExternalAction) {
    inbox.post(action)
  }

  var idleSince: Date? {
    guard archiveReservation == nil else { return nil }
    guard let liveState else { return lastCommandProcessedAt }
    guard let lhs = lastCommandProcessedAt,
          let rhs = liveState.lastUpdatedByLoopAt,
          liveState.hasSettled
    else { return nil }
    return max(lhs, rhs)
  }

  func tryRetire(ttl: Duration, now: Date) async -> Bool {
    guard let idleSince, now.timeIntervalSince(idleSince) >= ttl.timeInterval
    else { return false }
    // The park wake lives here; the process may end, the actor may not.
    if liveState?.parkWake != nil { return false }
    await shutdown()
    return true
  }

  func shutdown() async {
    retired = true
    taskScope.cancel()
    handlerTask?.cancel()
    handlerTask = nil
    dismountLive()
    await loopConfig.invalidateInference(id)
  }

  private func dismountLive() {
    liveState?.parkWake?.task.cancel()
    looperTask?.cancel()
    looperTask = nil
    longRunningTask?.task.cancel()
    longRunningTask = nil
    retryPause?.cancel()
    retryPause = nil
    nudges = nil
    liveState = nil
  }

  func nudge() {
    nudges?.post(())
  }

  private func runHandler() async {
    while let action = await inbox.next() {
      lastCommandProcessedAt = nil
      await handle(action: action)
      lastCommandProcessedAt = date()
    }
  }

  private func handle(action: ExternalAction) async {
    if archiveReservation != nil {
      switch action {
      case .wake, .enqueue, .archive, .releaseArchive: break
      case .prepareArchive(_, let callback):
        callback.resume(throwing: SessionError.archiveInProgress)
        return
      case .unarchive(let callback), .interrupt(let callback), .resume(let callback):
        callback.resume(throwing: SessionError.archiveInProgress)
        return
      case .restart(_, _, _, let callback):
        callback.resume(throwing: SessionError.archiveInProgress)
        return
      }
    }
    switch action {
    case .wake(let callback):
      await callback.run {
        guard try await ensureLifecycle() == .live else { return }
        try await handleWake()
      }
    case .enqueue(let item, let callback):
      await callback.run {
        try await handleEnqueue(item)
      }
    case .prepareArchive(let reservation, let callback):
      await callback.run {
        guard try await ensureLifecycle() == .live else {
          archiveReservation = reservation
          return true
        }
        let head = try await repo.queueHead()
        try modify { $0.queueHead = max($0.queueHead, head) }
        guard try live.hasSettled else { return false }
        try modify { $0.archiving = true }
        archiveReservation = reservation
        return true
      }
    case .releaseArchive(let reservation, let callback):
      await callback.run {
        guard archiveReservation == reservation else { return }
        archiveReservation = nil
        if liveState != nil {
          defer {
            liveState?.archiving = false
            nudge()
          }
          try await handleWake()
        }
      }
    case .archive(let reservation, let callback):
      await callback.run {
        guard archiveReservation == reservation else { throw SessionError.archiveReservationLost }
        try await handleArchive()
      }
    case .unarchive(let callback):
      await callback.run {
        try await handleUnarchive()
      }
    case .interrupt(let callback):
      await callback.run {
        try await handleInterrupt()
      }
    case .resume(let callback):
      await callback.run {
        try await handleResume()
      }
    case .restart(let executor, let note, let route, let callback):
      await callback.run {
        try await handleRestart(executor: executor, note: note, modelRoute: route)
      }
    }
  }

  private func ensureLifecycle() async throws -> Lifecycle {
    if let lifecycle {
      return lifecycle
    }

    let hydration = try await repo.hydrate()
    try Task.checkCancellation()
    switch hydration.record.lifecycle {
    case .archived(let graceExpiresAt):
      let status = Lifecycle.archived(graceExpiry: graceExpiresAt)
      lifecycle = status
      return status

    case .live:
      // The materialization self-nudge runs the loop once: orphan tool-call
      // repair is thereby unconditional — pending calls surface FIFO whether
      // or not the session was in the boot set.
      liveState = LiveState(hydration: hydration, now: date())
      mountLooper()
      lifecycle = .live
      return .live
    }
  }

  private func mountLooper() {
    let nudges = Inbox<Void>(coalescing: true)
    self.nudges = nudges
    looperTask = try? taskScope.run("session-loop") { await runLooper(nudges: nudges) }
    nudges.post(())
  }

  private func runLooper(nudges: Inbox<Void>) async {
    while await nudges.next() != nil {
      let token = liveness.start()
      defer { liveness.end(token) }
      do {
        try await loop()
        await afterLoop()
      } catch is CancellationError {
        return
      } catch {
        if !Task.isCancelled { await markErrored(error: error) }
      }
      if retired { return }
    }
  }

  // Every queue writer signals the work bus and lands here: deliveries written
  // straight to the repo bypass handleEnqueue, so a wake re-syncs the queue
  // head or the loop's drain check stays stale.
  private func handleWake() async throws {
    let head = try await repo.queueHead()
    try modify { $0.queueHead = max($0.queueHead, head) }
    nudge()
  }

  private func handleEnqueue(_ item: QueueInput) async throws -> Int {
    switch try await ensureLifecycle() {
    case .live:
      let id = try await repo.enqueue(input: item)
      try modify {
        $0.queueHead = max($0.queueHead, id)
      }
      nudge()
      return id

    case .archived(let deadline):
      guard date() < deadline else {
        throw SessionError.archiveGraceExpired
      }
      return try await repo.enqueue(input: item)
    }
  }

  private func handleArchive() async throws {
    guard try await ensureLifecycle() == .live else { return }

    // An owed idle check is no work, but no pass may start a turn while the
    // archive is written: the turn would land in the archived session.
    try modify { $0.archiving = true }
    let deadline = try await repo.archive(grace: loopConfig.archiveGrace)
    try Task.checkCancellation()
    lifecycle = .archived(graceExpiry: deadline)
    dismountLive()
    await loopConfig.invalidateInference(id)
  }

  // No ensureLifecycle: the store's refusal is the single gate, and
  // materializing here would run a loop pass on a session about to be wiped.
  private func handleRestart(executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    // Its frames would land in the fresh generation.
    let restart = try await repo.restart(executor: executor, note: note, modelRoute: modelRoute)
    try Task.checkCancellation()
    lifecycle = nil
    dismountLive()
    await loopConfig.invalidateInference(id)
    return restart
  }

  private func handleUnarchive() async throws {
    guard case .archived(let deadline) = try await ensureLifecycle() else { return }
    guard date() < deadline else {
      throw SessionError.archiveGraceExpired
    }
    try await repo.unarchive()
    try Task.checkCancellation()
    lifecycle = nil
    dismountLive()
    await loopConfig.invalidateInference(id)
  }

  private func handleInterrupt() async throws {
    guard try await ensureLifecycle() == .live else { return }
    switch try live.sessionStatus {
    case .interrupting:
      fatalError("Impossible: two concurrent interruption request!")
    case .interrupted, .errored:
      return
    case .healthy:
      break
    }

    longRunningTask?.task.cancel()
    retryPause?.cancel()
    // If an error is occurring at the same time for inference, the callback
    // will be lost, leading to an UnfulfilledError, and propagate back.
    try await withCallback(of: Void.self) { callback in
      try modify { $0.sessionStatus = .interrupting(callback) }
      // If the loop is currently idle, we use this nudge to fulfill the callback.
      nudge()
    }

    try await repo.markInterrupted()
    try modify { $0.sessionStatus = .interrupted }
  }

  private func handleResume() async throws {
    guard try await ensureLifecycle() == .live else { return }
    switch try live.sessionStatus {
    case .interrupting:
      fatalError("Impossible: interruption request inflight!")
    case .healthy:
      return
    case .interrupted, .errored(_):
      try await repo.markResumed()
      try modify {
        $0.sessionStatus = .healthy
      }
      nudge()
    }
  }
}

extension SessionActor.LiveState {
  init(hydration: SessionHydration, now: Date, mountID: UUID = UUID()) {
    let status: SessionActor.RunStatus = if hydration.record.hold == .interrupted {
      .interrupted
    } else if hydration.record.work == .errored {
      .errored(hydration.record.errorMessage ?? "unknown error")
    } else {
      .healthy
    }
    self.init(
      mountID: mountID,
      generation: hydration.generation,
      transcript: { switch hydration.transcript { case let .kernel(transcript): transcript } }(),
      queueHead: hydration.queueHead,
      queueTail: hydration.queueTail,
      sessionStatus: status,
      lastUpdatedByLoopAt: now,
      group: hydration.record.group.rawValue,
      isTask: hydration.record.kind == .task,
    )
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
