import Clocks
import Dependencies
import Foundation

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

  /// Yokes `\.date` and `\.continuousClock` to one `VirtualClock` so advancing time moves "now" too.
  public mutating func installTimeControl(anchor: Date = Date(timeIntervalSinceReferenceDate: 0)) {
    let clock = VirtualClock()
    continuousClock = AnyClock(clock)
    date = DateGenerator { anchor.addingTimeInterval(clock.now.offset.timeInterval) }
    timeControl = TimeControl(
      advance: { target in
        await clock.advance(by: clock.now.duration(to: VirtualClock.at(.seconds(target.timeIntervalSinceReferenceDate - anchor.timeIntervalSinceReferenceDate))))
      },
      pendingSleeps: { clock.pendingSleeps() },
      asleep: { seconds in try await clock.sleeping { $0.isDue(in: seconds) } },
    )
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
