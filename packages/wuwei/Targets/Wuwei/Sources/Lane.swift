import DequeModule
import Synchronization

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// One addressable's serial executor. The scheduler lends it a thread to run a few jobs; when its queue runs dry, or after `drainEvery` jobs if it never does, the drain hook runs before any new job can start.
public final class Lane: SerialExecutor {
  private struct Queue {
    var jobs = Deque<UnownedJob>()
    var scheduled = false
    var sinceDrain = 0
  }

  static let drainEvery = 256

  let scheduler: any Scheduler
  private let queue = Mutex(Queue())
  private let runner = Atomic<UInt>(0)
  private let drainHook = Mutex<Hook?>(nil)

  /// Kept in a struct: a bare function in a `Mutex` is wrapped once more every time it is read.
  private struct Hook: Sendable {
    let run: @Sendable () -> Void
  }

  init(scheduler: any Scheduler) {
    self.scheduler = scheduler
  }

  func onDrain(_ hook: @escaping @Sendable () -> Void) {
    drainHook.withLock { $0 = Hook(run: hook) }
  }

  public func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let wake = queue.withLock { queue in
      queue.jobs.append(job)
      defer { queue.scheduled = true }
      return !queue.scheduled
    }
    if wake { scheduler.schedule(self) }
  }

  public func isIsolatingCurrentContext() -> Bool? {
    runner.load(ordering: .acquiring) == currentThread()
  }

  /// Runs at most `limit` jobs, each one chosen by `pick` from the number waiting, and says whether the lane must be scheduled again: what a ``Scheduler`` does with a lane it was given.
  public func run(limit: Int, pick: (Int) -> Int) -> Bool {
    runner.store(currentThread(), ordering: .releasing)
    for _ in 0 ..< limit {
      guard let job = queue.withLock({ $0.jobs.isEmpty ? nil : $0.jobs.remove(at: pick($0.jobs.count)) }) else { break }
      // Naming the task executor too lets an await on this lane continue inline; with only the serial executor named, a task that prefers the scheduler hops through `enqueue` at every await.
      job.runSynchronously(isolatedTo: asUnownedSerialExecutor(), taskExecutor: scheduler.asUnownedTaskExecutor())
      let drained = queue.withLock { queue in
        queue.sinceDrain += 1
        guard queue.jobs.isEmpty || queue.sinceDrain == Self.drainEvery else { return false }
        queue.sinceDrain = 0
        return true
      }
      if drained { drainHook.withLock { $0 }?.run() }
    }
    // Before the lane is let go: once `scheduled` is false another thread may be running it, and a clear that came after would take the lane from that thread.
    runner.store(0, ordering: .releasing)
    return queue.withLock { queue in
      queue.scheduled = !queue.jobs.isEmpty
      return queue.scheduled
    }
  }
}

private func currentThread() -> UInt {
  #if canImport(Darwin)
    UInt(bitPattern: pthread_self())
  #else
    UInt(pthread_self())
  #endif
}
