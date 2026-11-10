#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dispatch

/// Where a process's lanes, its loose task jobs and the runtime's own events run, and what time it is there. Every task the runtime starts prefers this executor, so a resumed continuation comes back here rather than to the global pool.
public protocol Scheduler: TaskExecutor {
  var now: Instant { get }
  func schedule(_ lane: Lane)
  func post(_ event: @escaping @Sendable () -> Void)
  func at(_ deadline: Instant, _ event: @escaping @Sendable () -> Void)
}

/// The production scheduler: lanes take turns on a concurrent dispatch queue, a batch of jobs per turn, so one busy lane can't starve the rest.
public final class LiveScheduler: Scheduler {
  private let queue = DispatchQueue(label: "wuwei", attributes: .concurrent)
  private let batch: Int

  public init(batch: Int = 32) {
    self.batch = batch
  }

  public var now: Instant {
    Instant(milliseconds: Int64(Date().timeIntervalSince1970 * 1000))
  }

  public func schedule(_ lane: Lane) {
    queue.async {
      if lane.run(limit: self.batch, pick: { _ in 0 }) { self.schedule(lane) }
    }
  }

  public func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }

  public func post(_ event: @escaping @Sendable () -> Void) {
    queue.async(execute: event)
  }

  public func at(_ deadline: Instant, _ event: @escaping @Sendable () -> Void) {
    let delay = max(0, (deadline - now).milliseconds)
    queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: event)
  }
}
