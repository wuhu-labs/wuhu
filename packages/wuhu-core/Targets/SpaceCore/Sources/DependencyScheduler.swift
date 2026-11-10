import Clocks
import Dependencies
import Dispatch
import Synchronization
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// `LiveScheduler` on the injected date and clock, so a test that moves them moves the worker's time too. A stopgap: once the store and main run on wuwei, tests use its simulation and this goes.
final class DependencyScheduler: Scheduler {
  private let queue = DispatchQueue(label: "wuhu-loops", attributes: .concurrent)
  private let date: DateGenerator
  private let clock: any NonsendingClock<Duration>
  private let timers = Mutex<[UUID: Task<Void, Never>]?>([:])

  init() {
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    self.date = date
    self.clock = clock
  }

  var now: Instant {
    Instant(milliseconds: Int64((date.now.timeIntervalSince1970 * 1000).rounded(.down)))
  }

  func schedule(_ lane: Lane) {
    queue.async {
      if lane.run(limit: 32, pick: { _ in 0 }) { self.schedule(lane) }
    }
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }

  func post(_ event: @escaping @Sendable () -> Void) {
    queue.async(execute: event)
  }

  func at(_ deadline: Instant, _ event: @escaping @Sendable () -> Void) {
    // A clock nobody injected never comes due: a test that gave none has no time passing.
    guard !(clock is UnimplementedClock<Duration>) else { return }
    let clock = AnyClock(self.clock)
    let deadline = clock.now.advanced(by: deadline - now)
    let id = UUID()
    timers.withLock { timers in
      guard timers != nil else { return }
      timers![id] = Task { [clock, queue, weak self] in
        defer { self?.timers.withLock { _ = $0?.removeValue(forKey: id) } }
        do { try await clock.sleep(until: deadline, tolerance: nil) } catch { return }
        queue.async(execute: event)
      }
    }
  }

  /// No pending or later timer fires: a test's clock outlives the worker that drained.
  func stop() {
    for timer in timers.withLock({ timers in defer { timers = nil }; return timers?.values.map(\.self) ?? [] }) { timer.cancel() }
  }
}
