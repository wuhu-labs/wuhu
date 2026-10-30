import protocol Clocks.NonsendingClock
import Synchronization

/// A clock that moves only while a test drives it, so a deadline measured on it does not depend on how fast the host runs. Install
/// it as `\.continuousClock`; `run(through:_:)` moves time from one pending sleep to the next while its body runs, and never past
/// its limit. Code that must act by the limit therefore always gets to, however slow the host is, and code that would need time
/// past it waits for good, which the suite's time limit reports. Unlike `TestClock`, it wakes sleepers of any isolation, so it is the
/// clock for nonisolated code; an undriven one holds every sleep until it is cancelled.
public final class VirtualClock: NonsendingClock, Sendable {
  public struct Instant: InstantProtocol {
    public var offset: Duration
    public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    public func duration(to other: Instant) -> Duration { other.offset - offset }
    public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let id: UInt64
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct Waiter {
    let isDue: @Sendable (Duration) -> Bool
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
    var waiters: [UInt64: Waiter] = [:]
    var nextID: UInt64 = 0
    /// The driver, waiting for a sleep to start.
    var driver: CheckedContinuation<Void, Never>?
    /// A sleep started since the driver last looked.
    var started = false

    mutating func takeMetWaiters() -> [Waiter] {
      let met = waiters.filter { _, waiter in sleepers.contains { waiter.isDue(now.duration(to: $0.deadline)) } }
      for id in met.keys { waiters[id] = nil }
      return Array(met.values)
    }
  }

  private let state = Mutex(State())

  public init() {}

  public var now: Instant { state.withLock { $0.now } }
  public var minimumResolution: Duration { .zero }

  /// The instant `offset` after the clock's start.
  public static func at(_ offset: Duration) -> Instant { Instant(offset: offset) }

  public func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
    let id = state.withLock { state in
      state.nextID += 1
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        enum Start { case sleeping(CheckedContinuation<Void, Never>?, met: [Waiter]), due, cancelled }
        let start = state.withLock { state -> Start in
          if Task.isCancelled { return .cancelled }
          if deadline <= state.now { return .due }
          state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          defer { state.driver = nil }
          if state.driver == nil { state.started = true }
          return .sleeping(state.driver, met: state.takeMetWaiters())
        }
        switch start {
        case let .sleeping(driver, met):
          driver?.resume()
          for waiter in met { waiter.continuation.resume() }
        case .due: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let cancelled = state.withLock { state -> Sleeper? in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return state.sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Runs `body` while moving time forward: to the earliest pending sleep due by `limit`, waking every sleep due by then, and
  /// otherwise waiting for the next sleep to start. Time stands still once nothing pending is due by `limit`, and when `body` ends.
  /// Only one `run` may drive the clock at a time.
  public func run<T>(through limit: Instant, _ body: () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask {
        while !Task.isCancelled {
          let (due, met) = self.state.withLock { state -> ([Sleeper], [Waiter]) in
            state.started = false
            guard let earliest = state.sleepers.map(\.deadline).min(), earliest <= limit else { return ([], []) }
            state.now = max(state.now, earliest)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return (due, state.takeMetWaiters())
          }
          for waiter in met { waiter.continuation.resume() }
          if due.isEmpty {
            await self.nextStart()
          } else {
            for sleeper in due { sleeper.continuation.resume() }
            await Task.yield()
          }
        }
      }
      defer { tasks.cancelAll() }
      return try await body()
    }
  }

  /// Moves time to `target` at once, waking every pending sleep due by then; a sleep that starts later counts from the new now.
  public func advance(to target: Instant) {
    let (due, met) = state.withLock { state -> ([Sleeper], [Waiter]) in
      state.now = max(state.now, target)
      let now = state.now
      let due = state.sleepers.filter { $0.deadline <= now }
      state.sleepers.removeAll { $0.deadline <= now }
      return (due, state.takeMetWaiters())
    }
    for sleeper in due { sleeper.continuation.resume() }
    for waiter in met { waiter.continuation.resume() }
  }

  /// `advance(to:)` `duration` past now, yielding before and after as `TestClock` does, so what it wakes runs before it returns.
  public func advance(by duration: Duration = .zero) async {
    for _ in 0 ..< 20 { await Task.yield() }
    advance(to: now.advanced(by: duration))
    for _ in 0 ..< 20 { await Task.yield() }
  }

  /// Returns once a pending sleep is due in a duration `isDue` accepts, with no deadline of its own; throws `CancellationError` if
  /// its task is cancelled first.
  public func sleeping(where isDue: @escaping @Sendable (Duration) -> Bool) async throws {
    let id = state.withLock { state in
      state.nextID += 1
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let ready = state.withLock { state -> Result<Void, any Error>? in
          if Task.isCancelled { return .failure(CancellationError()) }
          if state.sleepers.contains(where: { isDue(state.now.duration(to: $0.deadline)) }) { return .success(()) }
          state.waiters[id] = Waiter(isDue: isDue, continuation: continuation)
          return nil
        }
        if let ready { continuation.resume(with: ready) }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
  }

  /// How far off each pending sleep is.
  public func pendingSleeps() -> [Duration] {
    state.withLock { state in state.sleepers.map { state.now.duration(to: $0.deadline) } }
  }

  /// Returns once a sleep has started since the driver last looked, or the driver is cancelled.
  private func nextStart() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (driver: CheckedContinuation<Void, Never>) in
        let waiting = state.withLock { state -> Bool in
          if state.started || Task.isCancelled { return false }
          state.driver = driver
          return true
        }
        if !waiting { driver.resume() }
      }
    } onCancel: {
      state.withLock { state in
        defer { state.driver = nil }
        return state.driver
      }?.resume()
    }
  }
}
