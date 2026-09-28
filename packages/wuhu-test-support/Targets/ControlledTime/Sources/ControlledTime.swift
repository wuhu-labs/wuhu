import Clocks
import Dependencies
import Foundation
import Synchronization

public struct TimeControl: Sendable {
  private let _advance: @Sendable (Date) async -> Void
  private let _pendingSleeps: @Sendable () -> [Duration]

  init(
    advance: @escaping @Sendable (Date) async -> Void,
    pendingSleeps: @escaping @Sendable () -> [Duration],
  ) {
    self._advance = advance
    self._pendingSleeps = pendingSleeps
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
    )
  }
}

public struct SleepTimeout: Error {}

extension TimeControl {
  /// Advancing wakes only sleeps that have started: one that starts after the
  /// advance counts from the new now and never wakes. A test that means to wake
  /// a sleep waits for it here first, polling for up to `timeout` of wall time,
  /// until a sleep due in `seconds` (to the millisecond) is pending. Several
  /// sleeps due at the same offset can't be told apart.
  public func asleep(
    _ description: String,
    dueIn seconds: Double,
    timeout: Duration = .seconds(10),
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
  ) async throws {
    let wall = ContinuousClock()
    let deadline = wall.now.advanced(by: timeout)
    while wall.now < deadline {
      if sleeping(dueIn: seconds) > 0 { return }
      try? await wall.sleep(for: .milliseconds(2))
    }
    reportIssue(
      "timed out waiting for \(description) to be asleep",
      fileID: fileID, filePath: filePath, line: line, column: column,
    )
    throw SleepTimeout()
  }

  /// `asleep`, then an advance a microsecond past that sleep's deadline.
  public func wake(
    _ description: String,
    after seconds: Double,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
  ) async throws {
    try await asleep(description, dueIn: seconds, fileID: fileID, filePath: filePath, line: line, column: column)
    @Dependency(\.date) var date
    await advance(to: date.now.addingTimeInterval(seconds + 1e-6))
  }

  /// How many pending sleeps are due in `seconds`, to the millisecond.
  public func sleeping(dueIn seconds: Double) -> Int {
    pendingSleeps.count { abs($0.timeInterval - seconds) < 1e-3 }
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
        await testClock.advance(
          to: TestClock.Instant(offset: .seconds(target.timeIntervalSinceReferenceDate - anchor.timeIntervalSinceReferenceDate)),
        )
      },
      pendingSleeps: { clock.pendingSleeps() },
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

  private let base: TestClock<Duration>
  private let pending = Mutex<[UUID: Instant]>([:])

  init(_ base: TestClock<Duration>) { self.base = base }

  var now: Instant { base.now }
  var minimumResolution: Duration { base.minimumResolution }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    pending.withLock { $0[id] = deadline }
    defer { pending.withLock { $0[id] = nil } }
    // A cancelled sleep leaves the record at once, not when its task next runs.
    try await withTaskCancellationHandler {
      try await base.sleep(until: deadline, tolerance: tolerance)
    } onCancel: {
      pending.withLock { $0[id] = nil }
    }
  }

  func pendingSleeps() -> [Duration] {
    let now = base.now
    return pending.withLock { $0.values.map { now.duration(to: $0) } }.filter { $0 > .zero }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (whole, atto) = components
    return TimeInterval(whole) + TimeInterval(atto) / 1e18
  }
}
