import Clocks
import Dependencies
import Foundation
import Synchronization

public struct TimeControl: Sendable {
  private let _advance: @Sendable (Date) async -> Void
  private let _pendingSleeps: @Sendable () -> [Duration]
  private let _asleep: @Sendable (Double) async throws -> Void

  init(
    advance: @escaping @Sendable (Date) async -> Void,
    pendingSleeps: @escaping @Sendable () -> [Duration],
    asleep: @escaping @Sendable (Double) async throws -> Void,
  ) {
    self._advance = advance
    self._pendingSleeps = pendingSleeps
    self._asleep = asleep
  }

  public func advance(to target: Date) async {
    await _advance(target)
  }

  /// How far off each sleep is that has started, has not returned and is due
  /// strictly later than now: suspended on the clock, or about to be. A woken
  /// or cancelled sleep is not listed.
  var pendingSleeps: [Duration] { _pendingSleeps() }

  static var unimplemented: TimeControl {
    TimeControl(
      advance: { _ in
        reportIssue("\\.timeControl is unimplemented. Install it with `installTimeControl()`.")
      },
      pendingSleeps: {
        reportIssue("\\.timeControl is unimplemented. Install it with `installTimeControl()`.")
        return []
      },
      asleep: { _ in
        reportIssue("\\.timeControl is unimplemented. Install it with `installTimeControl()`.")
      },
    )
  }
}

extension TimeControl {
  /// Advancing wakes only sleeps that have started: one that starts after the
  /// advance counts from the new now and never wakes. A test that means to wake
  /// a sleep waits for it here first: this returns once a sleep due in
  /// `seconds` (to the millisecond) is pending, with no deadline of its own, and
  /// throws `CancellationError` if its task is cancelled first. Several sleeps
  /// due at the same offset can't be told apart.
  public func asleep(_ description: String, dueIn seconds: Double) async throws {
    try await _asleep(seconds)
  }

  /// `asleep`, then an advance a microsecond past that sleep's deadline.
  public func wake(_ description: String, after seconds: Double) async throws {
    try await asleep(description, dueIn: seconds)
    @Dependency(\.date) var date
    await advance(to: date.now.addingTimeInterval(seconds + 1e-6))
  }

  /// How many pending sleeps are due in `seconds`, to the millisecond.
  public func sleeping(dueIn seconds: Double) -> Int {
    pendingSleeps.count { $0.isDue(in: seconds) }
  }

  /// How many sleeps are pending.
  public var sleepCount: Int { pendingSleeps.count }
}

private enum TimeControlKey: DependencyKey {
  static let liveValue: TimeControl = .unimplemented
  static let testValue: TimeControl = .unimplemented
}

extension DependencyValues {
  public var timeControl: TimeControl {
    get { self[TimeControlKey.self] }
    set { self[TimeControlKey.self] = newValue }
  }

  /// Yokes `\.date` and `\.continuousClock` to one `TestClock` so advancing time moves "now" too.
  public mutating func installTimeControl(anchor: Date = Date(timeIntervalSinceReferenceDate: 0)) {
    let testClock = TestClock<Duration>()
    let clock = TrackedClock(testClock)
    continuousClock = AnyClock(clock)
    date = DateGenerator {
      anchor.addingTimeInterval(TestClock<Duration>.Instant().duration(to: testClock.now).timeInterval)
    }
    timeControl = TimeControl(
      advance: { target in
        await clock.advance(
          to: TestClock.Instant(offset: .seconds(target.timeIntervalSinceReferenceDate - anchor.timeIntervalSinceReferenceDate)),
        )
      },
      pendingSleeps: { clock.pendingSleeps() },
      asleep: { seconds in try await clock.untilSleeping(dueIn: seconds) },
    )
  }
}

/// A `TestClock` that records its sleeps from when they start until they
/// return or are cancelled. A sleep is recorded before it suspends on the test
/// clock: an advance landing in between wakes it only if it goes strictly past
/// its deadline (the helpers overshoot by a microsecond); one landing exactly
/// on it leaves the sleep suspended until the next advance, as TestClock does
/// for any sleep until now.
private final class TrackedClock: Clock, Sendable {
  typealias Instant = TestClock<Duration>.Instant

  private struct Waiter {
    let seconds: Double
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var sleeps: [UUID: Instant] = [:]
    var waiters: [UUID: Waiter] = [:]

    mutating func waiters(metBy deadlines: some Sequence<Instant>, now: Instant) -> [Waiter] {
      let met = waiters.filter { _, waiter in deadlines.contains { now.duration(to: $0).isDue(in: waiter.seconds) } }
      for id in met.keys { waiters[id] = nil }
      return Array(met.values)
    }
  }

  private let base: TestClock<Duration>
  private let state = Mutex(State())

  init(_ base: TestClock<Duration>) { self.base = base }

  var now: Instant { base.now }
  var minimumResolution: Duration { base.minimumResolution }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    let met = state.withLock {
      $0.sleeps[id] = deadline
      return $0.waiters(metBy: [deadline], now: base.now)
    }
    for waiter in met { waiter.continuation.resume() }
    defer { state.withLock { $0.sleeps[id] = nil } }
    // A cancelled sleep leaves the record at once, not when its task next runs.
    try await withTaskCancellationHandler {
      try await base.sleep(until: deadline, tolerance: tolerance)
    } onCancel: {
      state.withLock { $0.sleeps[id] = nil }
    }
  }

  func advance(to instant: Instant) async {
    await base.advance(to: instant)
    let met = state.withLock { $0.waiters(metBy: $0.sleeps.values, now: base.now) }
    for waiter in met { waiter.continuation.resume() }
  }

  func untilSleeping(dueIn seconds: Double) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let ready: Result<Void, any Error>? = state.withLock { state in
          if Task.isCancelled { return .failure(CancellationError()) }
          if state.sleeps.values.contains(where: { base.now.duration(to: $0).isDue(in: seconds) }) { return .success(()) }
          state.waiters[id] = Waiter(seconds: seconds, continuation: continuation)
          return nil
        }
        if let ready { continuation.resume(with: ready) }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
  }

  func pendingSleeps() -> [Duration] {
    let now = base.now
    return state.withLock { $0.sleeps.values.map { now.duration(to: $0) } }.filter { $0 > .zero }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (whole, atto) = components
    return TimeInterval(whole) + TimeInterval(atto) / 1e18
  }

  fileprivate func isDue(in seconds: Double) -> Bool {
    self > .zero && abs(timeInterval - seconds) < 1e-3
  }
}
