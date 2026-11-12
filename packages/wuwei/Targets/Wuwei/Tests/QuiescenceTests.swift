import Synchronization
import Testing
@testable import Wuwei

@Job
struct SlowCancellation {
  typealias Params = Int
  typealias Message = Never

  mutating func start() async throws -> Outcome {
    let valve = ctx.dependency(Valve.self)
    do {
      try await ctx.effect { try await valve.wait("start") }
    } catch is CancellationError {
      await valve.pass("cleanup")
    }
    return .notDone
  }
}

@Suite struct QuiescenceTests {
  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func aDueWakeCannotWriteAfterQuiescence(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Alarm.self)])
    let alarm = Alarm.ID("due")
    a.worker.send(alarm).set(world.simulation.now + .seconds(2))
    world.run(for: .seconds(1))
    world.simulation.freeze(a.process)
    world.run(for: .seconds(2))
    let control = world.simulation.spawn()
    let quiesced = Mutex(false)
    Task(executorPreference: control) {
      await a.worker.quiesce()
      quiesced.withLock { $0 = true }
    }
    world.run(for: .zero)
    world.simulation.thaw(a.process)
    world.run(for: .seconds(1))
    #expect(quiesced.withLock { $0 })
    #expect(a.worker.cell(alarm).rang().isEmpty)
    let refused = Mutex(false)
    Task(executorPreference: control) {
      do {
        _ = try await a.worker.call(alarm) { _ in true }
        Issue.record("a quiesced worker admitted a call")
      } catch is Evicted {
        refused.withLock { $0 = true }
      } catch {
        Issue.record(error)
      }
    }
    #expect(a.worker.attach(Feed.self, to: alarm, opening: 0) { _ in } == nil)
    world.run(for: .seconds(15))
    #expect(refused.withLock { $0 })
    #expect(a.worker.cell(alarm).rang().isEmpty)
    a.worker.release()
  }

  @Test func aRetirementQueuedBeforeQuiescenceKeepsItsLease() throws {
    let world = World()
    let a = try world.node("a", [.cell(Counter.self)])
    let counter = Counter.ID("retiring")
    a.worker.send(counter).add(1)
    world.run(for: .seconds(1))
    let row = try #require(a.worker.store.read {
      try $0.rows("SELECT id, fence, page_count FROM wuwei_addressable WHERE address = ?", .text(counter.description)).first
    })
    let retirement = Epoch(address: counter.description, lease: Lease(id: row["id"].integer!, fence: row["fence"].integer!), number: 2, pages: [:], pageCount: UInt32(row["page_count"].integer!), writes: [.released])
    world.simulation.freeze(a.process)
    let shipped = Mutex(false)
    a.worker.shipper.ship(retirement) { result in
      #expect(throws: Never.self) { try result.get() }
      shipped.withLock { $0 = true }
    }
    let control = world.simulation.spawn()
    Task(executorPreference: control) { await a.worker.quiesce() }
    world.run(for: .zero)
    world.simulation.thaw(a.process)
    world.run(for: .seconds(1))
    #expect(shipped.withLock { $0 })
    let b = try world.node("b", [.cell(Counter.self)])
    b.worker.send(counter).add(10)
    world.run(for: .seconds(15))
    #expect(b.worker.hasMail(for: counter.recipient))
    #expect(b.worker.cell(counter).value() == 1)
    a.worker.release()
    world.run(for: .seconds(2))
    #expect(b.worker.cell(counter).value() == 11)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func anIdleCellKeepsItsLeaseWhileAnotherHostUnwinds(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(SlowCancellation.self), .cell(Counter.self)], dependencies: dependencies)
    let counter = Counter.ID("held")
    try a.worker.create(SlowCancellation.ID("slow"), params: 0)
    a.worker.send(counter).add(1)
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == ["start"])
    let quiesced = Mutex(false)
    Task(executorPreference: a.process) {
      await a.worker.quiesce()
      quiesced.withLock { $0 = true }
    }
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == ["cleanup"])
    let b = try world.node("b", [.job(SlowCancellation.self), .cell(Counter.self)], dependencies: dependencies)
    b.worker.send(counter).add(10)
    world.run(for: .seconds(5))
    #expect(!quiesced.withLock { $0 })
    #expect(b.worker.hasMail(for: counter.recipient))
    #expect(b.worker.cell(counter).value() == 1)
    valve.open("cleanup")
    world.run(for: .seconds(1))
    #expect(quiesced.withLock { $0 })
    a.worker.release()
    world.run(for: .seconds(2))
    #expect(b.worker.cell(counter).value() == 11)
  }
}
