import Dependencies
import class MainHub.Callback
import protocol MainHub.Main
import enum MainHub.RevocationPolicy
import enum MainHub.SessionError
import struct MainHub.UnfulfilledError
import func MainHub.withCallback
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct ServerTelemetry.CacheExpectation
import SessionDomain
import SpaceCore

actor SessionActor {
  enum Lifecycle: Hashable {
    case live
    case archived
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
    let parent: SessionID?
    var delegatedWake = false
    var parkWake: (at: Date, task: Task<Void, Never>)?
    var revoking = false
    var claimingCompactRequest = false
    /// A step of the pass is under way; a normal inference's step ends at its commit, before the post-commit callback.
    var inStep = false
    var malformedMessages = 0
    var capacityFailures = 0
    var compactedForPayload = false
    var turnsSinceMount = 0
    var lastPrompt: LastPrompt?

    /// The last reply's whole prompt, for the next attempt's cache expectation; only in the generation that made it.
    struct LastPrompt {
      let tokens: Int
      let at: Date
      let generation: Int
    }

    func cacheExpectation(now: Date) -> CacheExpectation? {
      guard let lastPrompt, lastPrompt.generation == generation else { return nil }
      return CacheExpectation(tokens: lastPrompt.tokens, idleMs: max(0, Int((now.timeIntervalSince(lastPrompt.at) * 1000).rounded())))
    }

    var hasSettled: Bool { lastUpdatedByLoopAt != nil && hasNothingLeft }

    var hasNothingLeft: Bool {
      if sessionStatus.stopped { return true }
      guard !claimingCompactRequest, compactRequestClaim == nil, queueHead == queueTail else { return false }
      return !transcript.hasWork
    }
  }

  enum ExternalAction {
    case wake(Callback<Void>)
    case prepareRevoke(RevocationPolicy, Callback<Bool>)
    case interrupt(Callback<Void>)
    case resume(Callback<Void>)

    func fail(_ error: any Error) {
      switch self {
      case .wake(let callback), .interrupt(let callback), .resume(let callback): callback.resume(throwing: error)
      case .prepareRevoke(_, let callback): callback.resume(throwing: error)
      }
    }

    func acknowledgeRevocation() {
      if case .wake(let callback) = self { callback.resume(returning: ()) }
      else { fail(SessionError.archiveInProgress) }
    }
  }

  nonisolated let id: SessionID
  let main: any Main
  let loopConfig: LoopConfig
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
  var inFlightTool: ToolInvocation?
  private var passInFlight = false
  private var passObservers: [CheckedContinuation<Void, Never>] = []
  var retryPause: Task<Void, any Error>?
  /// A normal-mode retry wait is `open` to a compact command; a wake that finds one pending ends it.
  var compactYield = CompactYield.closed
  enum CompactYield { case closed, open, requested }
  private var retired = false

  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  @Dependency(\.continuousClock) var clock
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  init(id: SessionID, main: any Main, loopConfig: LoopConfig, beforeCompactRequest: @escaping @Sendable () async -> Void = {}, afterLoop: @escaping @Sendable () async -> Void = {}) {
    self.id = id
    self.main = main
    self.loopConfig = loopConfig
    self.beforeCompactRequest = beforeCompactRequest
    self.afterLoop = afterLoop
  }

  func activate(in owner: TaskScope) {
    precondition(handlerTask == nil, "SessionActor activates once")
    guard !retired else { return }
    handlerTask = try? owner.run("session-handler") { await runHandler() }
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
    guard liveState?.revoking != true else { return nil }
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
    defer { taskScope.cancel() }
    while let action = await inbox.next() {
      lastCommandProcessedAt = nil
      await handle(action: action)
      lastCommandProcessedAt = date()
    }
  }

  private func handle(action: ExternalAction) async {
    switch action {
    case .wake(let callback):
      await callback.run {
        guard try await ensureLifecycle() == .live else { return }
        try await handleWake()
      }
    case .prepareRevoke(let policy, let callback):
      await callback.run {
        guard try await ensureLifecycle(startLoop: false) == .live else { return true }
        switch policy {
        case .cancel:
          return true
        case .whenSettled:
          let head = try await main.queueHead(id)
          try modify { $0.queueHead = max($0.queueHead, head) }
          if try !live.hasSettled {
            guard try isFinishingPass, try await main.pendingCommand(id) == nil, try live.hasSettled || isFinishingPass else { return false }
          }
          try modify { $0.revoking = true }
          await passEnded()
          return true
        case .handOff:
          // The loop returns at its next boundary; a releasable tool is cut
          // now and stays pending, so the next worker picks it up.
          try modify { $0.revoking = true }
          if let invocation = inFlightTool, await loopConfig.releaseTool(invocation) {
            longRunningTask?.task.cancel()
          }
          await passEnded()
          return true
        }
      }
    case .interrupt(let callback):
      await callback.run {
        try await handleInterrupt()
      }
    case .resume(let callback):
      await callback.run {
        try await handleResume()
      }
    }
  }

  // A pass between steps with nothing left: once revoking, it takes no further step.
  private var isFinishingPass: Bool {
    get throws { try passInFlight && !live.inStep && live.hasNothingLeft }
  }

  // Suspends until the pass in flight, if any, has returned: what it knew is
  // then in the store, and nothing of this session runs here.
  private func passEnded() async {
    guard passInFlight else { return }
    await withCheckedContinuation { passObservers.append($0) }
  }

  private func ensureLifecycle(startLoop: Bool = true) async throws -> Lifecycle {
    if let lifecycle {
      if startLoop, lifecycle == .live, looperTask == nil { mountLooper() }
      return lifecycle
    }

    let hydration = try await main.hydrate(id)
    try Task.checkCancellation()
    switch hydration.record.lifecycle {
    case .archived:
      let status = Lifecycle.archived
      lifecycle = status
      return status

    case .live:
      let live = LiveState(hydration: hydration, now: date())
      await loopConfig.mounted(id, live.transcript)
      try Task.checkCancellation()
      liveState = live
      if startLoop { mountLooper() }
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
      passInFlight = true
      await runPass()
      passInFlight = false
      let observers = passObservers
      passObservers.removeAll()
      for observer in observers { observer.resume() }
      if retired { return }
    }
  }

  private func runPass() async {
    let mountID = liveState?.mountID
    liveState?.lastUpdatedByLoopAt = nil
    liveState?.inStep = false
    defer {
      if liveState?.mountID == mountID { liveState?.lastUpdatedByLoopAt = date() }
    }
    do {
      try await loop()
      await afterLoop()
    } catch is CancellationError {
      return
    } catch {
      if !Task.isCancelled { await markErrored(error: error) }
    }
  }

  // Every queue writer signals the work bus and lands here: deliveries written
  // straight to the store bypass handleEnqueue, so a wake re-syncs the queue
  // head or the loop's drain check stays stale.
  private func handleWake() async throws {
    let head = try await main.queueHead(id)
    try modify { $0.queueHead = max($0.queueHead, head) }
    if compactYield == .open, try await main.pendingCommand(id) != nil, compactYield == .open {
      compactYield = .requested
      retryPause?.cancel()
    }
    nudge()
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

    try await main.append(id, .interrupted).value(Void.self)
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
      try await main.append(id, .resumed).value(Void.self)
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
      parent: hydration.record.parent,
    )
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
