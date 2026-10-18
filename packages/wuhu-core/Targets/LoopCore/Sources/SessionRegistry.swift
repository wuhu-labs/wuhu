import Dependencies
import Synchronization
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import protocol SpaceCore.MainClient

actor SessionRegistry {
  private let main: any MainClient
  private let loopConfig: LoopConfig
  private let liveness: LivenessTracker

  private(set) var sessions: [SessionID: SessionActor] = [:]
  private enum State {
    case active
    case stopping(AsyncStream<Void>)
    case stopped
  }

  private var state = State.active
  private var stopped: Bool { if case .active = state { false } else { true } }
  private nonisolated let taskScope = TaskScope()
  private nonisolated let admission = Mutex(true)
  private var reaper: Task<Void, Never>?

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date) private var date

  init(
    main: any MainClient,
    loopConfig: LoopConfig,
    liveness: LivenessTracker,
  ) {
    self.main = main
    self.loopConfig = loopConfig
    self.liveness = liveness
  }

  func activate() {
    precondition(reaper == nil, "SessionRegistry activates once")
    reaper = try? taskScope.run("session-reaper") { await runReaper() }
  }

  nonisolated func send(_ action: SessionActor.ExternalAction, to id: SessionID) {
    admission.withLock { open in
      guard open else { return }
      _ = try? taskScope.run("session-command") { await self.post(action, to: id) }
    }
  }

  func post(_ action: SessionActor.ExternalAction, to id: SessionID) async {
    guard !stopped else { return }
    let session: SessionActor
    if let existing = sessions[id] {
      session = existing
    } else {
      // Unknown ids surface as unknownSession from the verb's first repo
      // call; the placeholder actor is reaped like any idle session.
      session = SessionActor(id: id, main: main, loopConfig: loopConfig, liveness: liveness)
      sessions[id] = session
      await session.activate()
    }
    guard !stopped else { return }
    session.post(action)
  }

  func existing(_ id: SessionID) -> SessionActor? {
    sessions[id]
  }

  func discard(_ id: SessionID) async {
    guard let session = sessions.removeValue(forKey: id) else { return }
    await retire(session)
  }

  func stop() async {
    switch state {
    case let .stopping(finished):
      await uncancellable("Join an already-running registry shutdown") { for await _ in finished {} }
      return
    case .stopped: return
    case .active: break
    }
    let (finished, signal) = AsyncStream<Void>.makeStream()
    state = .stopping(finished)
    admission.withLock { $0 = false }
    let reaper = self.reaper
    reaper?.cancel()
    self.reaper = nil
    await reaper?.value
    let current = Array(sessions.values)
    sessions.removeAll()
    for session in current { await retire(session) }
    await taskScope.close()
    state = .stopped
    signal.finish()
  }

  private func retire(_ session: SessionActor) async {
    let (dismounted, signal) = AsyncStream<Void>.makeStream()
    do {
      try taskScope.run("retired-session-drain") {
        await session.shutdown()
        signal.finish()
        await session.taskScope.close()
      }
    } catch {
      await session.shutdown()
      signal.finish()
      await session.taskScope.close()
    }
    for await _ in dismounted {}
  }

  // One eviction site, both policies: the periodic sweep retires settled
  // sessions idle past the TTL, and past maxIdle it retires oldest-idle
  // first. The verdict is the session's own (tryRetire refuses while busy);
  // write-through makes retirement safe and the next verb rehydrates.
  private func runReaper() async {
    let policy = loopConfig.eviction
    while !Task.isCancelled {
      guard (try? await clock.sleep(for: policy.sweepInterval)) != nil else { return }
      await sweep(policy: policy)
    }
  }

  private func sweep(policy: EvictionPolicy) async {
    let now = date()
    var idle: [(id: SessionID, session: SessionActor, since: Date)] = []
    for (id, session) in sessions {
      guard let since = await session.idleSince else { continue }
      idle.append((id: id, session: session, since: since))
    }
    idle.sort { $0.since < $1.since }

    var ttl: [SessionID: Duration] = [:]
    for entry in idle {
      ttl[entry.id] = policy.idleTTL
    }
    for entry in idle.dropLast(policy.maxIdle) {
      ttl[entry.id] = .zero
    }

    for entry in idle {
      guard await entry.session.tryRetire(ttl: ttl[entry.id]!, now: now) else { continue }
      sessions.removeValue(forKey: entry.id)
      _ = try? taskScope.run("retired-session-drain") { await entry.session.taskScope.close() }
    }
  }
}
