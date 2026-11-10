import Dispatch
import Synchronization

/// A deterministic world for tests. The lanes, loose task jobs, events and timers of every simulated process run one at a time on the thread that calls `run`, in an order drawn from a seeded generator, under a virtual clock that moves only when nothing is ready. A due timer is one more ready step: it can come between any two others.
public final class Simulation: Sendable {
  fileprivate enum Work {
    case lane(Lane)
    case job(UnownedJob, SimulatedProcess)
    case event(@Sendable () -> Void)
  }

  private struct Timer {
    let deadline: Instant
    let process: Int
    let event: @Sendable () -> Void
  }

  private struct World {
    var random: SplitMix64
    var now: Instant
    var ready: [(process: Int, work: Work)] = []
    var timers: [Timer] = []
    var dead: Set<Int> = []
    var frozen: Set<Int> = []
    var processes = 0
  }

  private let world: Mutex<World>

  public init(seed: UInt64, start: Instant = Instant(milliseconds: 1_800_000_000_000)) {
    world = Mutex(World(random: SplitMix64(state: seed), now: start))
  }

  public var now: Instant {
    world.withLock { $0.now }
  }

  public func spawn() -> SimulatedProcess {
    SimulatedProcess(simulation: self, id: world.withLock { world in
      world.processes += 1
      return world.processes
    })
  }

  /// Everything the process had ready or pending disappears, mid-await included, as it would in a crash.
  public func kill(_ process: SimulatedProcess) {
    world.withLock { world in
      world.dead.insert(process.id)
      world.ready.removeAll { $0.process == process.id }
      world.timers.removeAll { $0.process == process.id }
    }
  }

  /// The process stops running, as in a long pause or a partition, while time goes on; `thaw` lets it run whatever came due meanwhile.
  public func freeze(_ process: SimulatedProcess) {
    world.withLock { _ = $0.frozen.insert(process.id) }
  }

  public func thaw(_ process: SimulatedProcess) {
    world.withLock { _ = $0.frozen.remove(process.id) }
  }

  public func run(for duration: Duration) {
    let end = now + duration
    let watchdog = Watchdog()
    defer { watchdog.stop() }
    while let work = next(until: end) {
      watchdog.enter()
      switch work {
      case let .lane(lane):
        if lane.run(limit: 1, pick: pick) { lane.scheduler.schedule(lane) }
      case let .job(job, process):
        job.runSynchronously(on: process.asUnownedTaskExecutor())
      case let .event(event):
        event()
      }
      watchdog.leave()
    }
  }

  private func next(until end: Instant) -> Work? {
    world.withLock { world in
      let frozen = world.frozen
      while true {
        let ready = world.ready.indices.filter { !frozen.contains(world.ready[$0].process) }
        let timers = world.timers.indices.filter { !frozen.contains(world.timers[$0].process) }
        let due = timers.filter { world.timers[$0].deadline <= world.now }
        if let pick = (0 ..< ready.count + due.count).randomElement(using: &world.random) {
          guard pick < ready.count else { return .event(world.timers.remove(at: due[pick - ready.count]).event) }
          world.ready.swapAt(ready[pick], world.ready.count - 1)
          return world.ready.removeLast().work
        }
        guard let soonest = timers.map({ world.timers[$0].deadline }).min(), soonest <= end else {
          world.now = max(world.now, end)
          return nil
        }
        world.now = soonest
      }
    }
  }

  private func pick(_ count: Int) -> Int {
    world.withLock { Int.random(in: 0 ..< count, using: &$0.random) }
  }

  fileprivate func ready(_ work: Work, in process: Int) {
    world.withLock { world in
      if !world.dead.contains(process) { world.ready.append((process, work)) }
    }
  }

  fileprivate func at(_ deadline: Instant, in process: Int, _ event: @escaping @Sendable () -> Void) {
    world.withLock { world in
      guard !world.dead.contains(process) else { return }
      world.timers.append(Timer(deadline: deadline, process: process, event: event))
    }
  }
}

/// One process of a ``Simulation``: the scheduler a worker of that process runs on.
public final class SimulatedProcess: Scheduler {
  let simulation: Simulation
  let id: Int

  fileprivate init(simulation: Simulation, id: Int) {
    self.simulation = simulation
    self.id = id
  }

  public var now: Instant {
    simulation.now
  }

  public func schedule(_ lane: Lane) {
    simulation.ready(.lane(lane), in: id)
  }

  public func enqueue(_ job: consuming ExecutorJob) {
    simulation.ready(.job(UnownedJob(job), self), in: id)
  }

  public func post(_ event: @escaping @Sendable () -> Void) {
    simulation.ready(.event(event), in: id)
  }

  public func at(_ deadline: Instant, _ event: @escaping @Sendable () -> Void) {
    simulation.at(deadline, in: id, event)
  }
}

/// Crashes the test process when one simulated step has run for a second of real time: no step of a test should, and the backtrace (`SWIFT_BACKTRACE=threads=all`) shows where it is stuck.
private final class Watchdog: Sendable {
  private let entered = Atomic<UInt64>(0)
  private let busy = Atomic<Bool>(false)
  private let stopped = Atomic<Bool>(false)

  init() {
    tick(lastEntered: 0, wasBusy: false)
  }

  func enter() {
    entered.add(1, ordering: .relaxed)
    busy.store(true, ordering: .relaxed)
  }

  func leave() {
    busy.store(false, ordering: .relaxed)
  }

  func stop() {
    stopped.store(true, ordering: .relaxed)
  }

  private func tick(lastEntered: UInt64, wasBusy: Bool) {
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) { [self] in
      guard !stopped.load(ordering: .relaxed) else { return }
      let entered = entered.load(ordering: .relaxed), busy = busy.load(ordering: .relaxed)
      if busy, wasBusy, entered == lastEntered { fatalError("a simulated step has been running for over a second") }
      tick(lastEntered: entered, wasBusy: busy)
    }
  }
}

private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
