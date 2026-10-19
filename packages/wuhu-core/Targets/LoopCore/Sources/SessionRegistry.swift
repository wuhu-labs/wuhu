import Dependencies
import SessionTools
import Synchronization
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import protocol SessionTools.Main

actor SessionRegistry {
  private let main: any Main
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

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date) private var date

  init(
    main: any Main,
    loopConfig: LoopConfig,
    liveness: LivenessTracker,
  ) {
    self.main = main
    self.loopConfig = loopConfig
    self.liveness = liveness
  }

  func activate() {
    let clock = clock, policy = loopConfig.eviction
    _ = try? taskScope.run("session-reaper", isolation: nil) { @Sendable [weak self] in
      while !Task.isCancelled {
        guard (try? await clock.sleep(for: policy.sweepInterval)) != nil else { return }
        await self?.sweep(policy: policy)
      }
    }
  }

  deinit { taskScope.cancel() }

  nonisolated func send(_ action: SessionActor.ExternalAction, to id: SessionID) {
    admission.withLock { open in
      guard open else { return }
      _ = try? taskScope.run("session-command") { await self.post(action, to: id) }
    }
  }

  func post(_ action: SessionActor.ExternalAction, to id: SessionID) async {
    guard !stopped else { return }
    if sessions[id] == nil {
      do { _ = try await main.record(id) }
      catch { action.fail(error); return }
    }
    guard !stopped else { return }
    let session: SessionActor
    if let existing = sessions[id] {
      session = existing
    } else {
      session = SessionActor(id: id, main: main, loopConfig: loopConfig, liveness: liveness)
      sessions[id] = session
      await session.activate(in: taskScope)
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
    taskScope.cancel()
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
