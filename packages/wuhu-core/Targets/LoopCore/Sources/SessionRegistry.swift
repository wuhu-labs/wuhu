import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID

actor SessionRegistry {
  private let makeRepo: @Sendable (SessionID) -> SessionRepo
  private let loopConfig: LoopConfig
  private let liveness: LivenessTracker

  private(set) var sessions: [SessionID: SessionActor] = [:]
  private var stopped = false
  private var reaper: Task<Void, Never>?

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date) private var date

  init(
    makeRepo: @escaping @Sendable (SessionID) -> SessionRepo,
    loopConfig: LoopConfig,
    liveness: LivenessTracker,
  ) {
    self.makeRepo = makeRepo
    self.loopConfig = loopConfig
    self.liveness = liveness
  }

  func activate() {
    precondition(reaper == nil, "SessionRegistry activates once")
    reaper = Task { await runReaper() }
  }

  func post(_ action: SessionActor.ExternalAction, to id: SessionID) async {
    guard !stopped else { return }
    let session: SessionActor
    if let existing = sessions[id] {
      session = existing
    } else {
      // Unknown ids surface as unknownSession from the verb's first repo
      // call; the placeholder actor is reaped like any idle session.
      session = SessionActor(id: id, repo: makeRepo(id), loopConfig: loopConfig, liveness: liveness)
      sessions[id] = session
      await session.activate()
    }
    guard !stopped else { return }
    session.post(action)
  }

  func existing(_ id: SessionID) -> SessionActor? {
    sessions[id]
  }

  func stop() async {
    stopped = true
    let reaper = self.reaper
    reaper?.cancel()
    self.reaper = nil
    await reaper?.value
    for session in sessions.values {
      await session.shutdown()
    }
    sessions.removeAll()
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
    }
  }
}
