import Dependencies
import enum MainHub.SessionError
import func MainHub.withCallback
import Synchronization
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol MainHub.Main
import enum MainHub.RevocationPolicy
import struct SessionDomain.SessionID

actor SessionRegistry {
  private let main: any Main
  private let loopConfig: LoopConfig

  private enum Slot {
    case mounted(SessionActor)
    case revoking(SessionActor?)
    case revoked

    var actor: SessionActor? {
      switch self {
      case let .mounted(actor), let .revoking(actor?): actor
      case .revoking(nil), .revoked: nil
      }
    }
  }

  private var slots: [SessionID: Slot] = [:]
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
  ) {
    self.main = main
    self.loopConfig = loopConfig
  }

  /// The sessions whose loops are mounted here.
  func mounted() -> [SessionID] {
    slots.compactMap { id, slot in
      guard case .mounted = slot else { return nil }
      return id
    }.sorted { $0.rawValue < $1.rawValue }
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

  private func admits(_ id: SessionID) -> Bool {
    switch slots[id] {
    case nil, .mounted: return true
    case .revoking, .revoked: return false
    }
  }

  func post(_ action: SessionActor.ExternalAction, to id: SessionID) async {
    guard !stopped else { return }
    guard admits(id) else { action.acknowledgeRevocation(); return }
    if slots[id] == nil {
      do { _ = try await main.record(id) }
      catch { action.fail(error); return }
    }
    guard !stopped else { return }
    guard admits(id) else { action.acknowledgeRevocation(); return }
    let session: SessionActor
    if case let .mounted(existing)? = slots[id] {
      session = existing
    } else {
      session = SessionActor(id: id, main: main, loopConfig: loopConfig)
      slots[id] = .mounted(session)
      await session.activate(in: taskScope)
    }
    guard !stopped else { return }
    session.post(action)
  }

  func revoke(_ id: SessionID, policy: RevocationPolicy) async throws -> Bool {
    guard !stopped else { throw CancellationError() }
    if case .revoked? = slots[id] {
      return true
    }
    if case .revoking? = slots[id] { throw SessionError.archiveInProgress }
    var session = slots[id]?.actor
    slots[id] = .revoking(session)
    do {
      switch policy {
      case .cancel: break
      case .handOff:
        // Nothing of an unmounted session is here: it is handed off at once.
        if let mounted = session {
          _ = try await withCallback(of: Bool.self) { mounted.post(.prepareRevoke(.handOff, $0)) }
        }
      case .whenSettled:
        let mounted: SessionActor
        if let existing = session { mounted = existing }
        else {
          let record = try await main.record(id)
          guard !stopped else { throw CancellationError() }
          if record.hold == .interrupted || record.work == .errored {
            slots[id] = .revoked
            return true
          }
          mounted = SessionActor(id: id, main: main, loopConfig: loopConfig)
          session = mounted
          slots[id] = .revoking(mounted)
          await mounted.activate(in: taskScope)
        }
        let settled = try await withCallback(of: Bool.self) { mounted.post(.prepareRevoke(.whenSettled, $0)) }
        guard settled else {
          guard !stopped else { throw CancellationError() }
          slots[id] = .mounted(mounted)
          try await withCallback(of: Void.self) { mounted.post(.wake($0)) }
          return false
        }
      }
      if let session {
        await session.shutdown()
        await session.taskScope.close()
      }
      guard !stopped else { throw CancellationError() }
      switch policy {
      case .whenSettled, .handOff: slots[id] = .revoked
      case .cancel: slots[id] = nil
      }
      return true
    } catch {
      if !stopped, case let .revoking(mounted)? = slots[id] {
        slots[id] = mounted.map(Slot.mounted)
      }
      throw error
    }
  }

  func archived(_ id: SessionID) {
    if case .revoked? = slots[id] { slots[id] = nil }
  }

  func reload(_ id: SessionID) async throws {
    if case .revoking? = slots[id] { throw SessionError.archiveInProgress }
    if case .revoked? = slots[id] { slots[id] = nil }
    _ = try await revoke(id, policy: .cancel)
    try await withCallback(of: Void.self) { send(.wake($0), to: id) }
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
    let current = slots.values.compactMap(\.actor)
    slots.removeAll()
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

  private func isMounted(_ actor: SessionActor, at id: SessionID) -> Bool {
    guard case let .mounted(current)? = slots[id] else { return false }
    return current === actor
  }

  // One eviction site, both policies: the periodic sweep retires settled
  // sessions idle past the TTL, and past maxIdle it retires oldest-idle
  // first. The verdict is the session's own (tryRetire refuses while busy);
  // write-through makes retirement safe and the next verb rehydrates.
  private func sweep(policy: EvictionPolicy) async {
    let now = date()
    var idle: [(id: SessionID, session: SessionActor, since: Date)] = []
    for (id, slot) in slots {
      guard case let .mounted(session) = slot else { continue }
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
      guard isMounted(entry.session, at: entry.id) else { continue }
      guard await entry.session.tryRetire(ttl: ttl[entry.id]!, now: now) else { continue }
      if isMounted(entry.session, at: entry.id) { slots[entry.id] = nil }
      _ = try? taskScope.run("retired-session-drain") { await entry.session.taskScope.close() }
    }
  }
}
