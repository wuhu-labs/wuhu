import Synchronization
import Testing
import Wuwei

@Suite struct HeldCallTests {
  private let counter = Counter.ID("held")

  private func ask(_ node: Node) -> (answer: Asked, task: Task<Void, Never>) {
    let answer = Asked()
    let counter = counter
    let task = Task(executorPreference: node.process) {
      let result: Result<Int64, any Error>
      do { result = .success(try await node.worker.call(counter) { try $0.addThenRead(10) }) }
      catch { result = .failure(error) }
      answer.heard.withLock { $0 = (result, node.worker.cell(counter).value()) }
    }
    return (answer, task)
  }

  private func drain(_ node: Node, in world: World) {
    Task(executorPreference: node.process) { await node.worker.quiesce() }
    world.run(for: .zero)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func aCallHoldsAsSoonAsQuiescenceBeginsWhileAJobFinishes(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.cell(Counter.self), .job(SlowCancellation.self)], dependencies: dependencies)
    try a.worker.create(SlowCancellation.ID("finishing"), params: 0)
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    #expect(valve.waitingLabels == ["start"])
    world.simulation.freeze(a.process)
    let control = world.simulation.spawn()
    let quiesced = Mutex(false)
    Task(executorPreference: control) {
      await a.worker.quiesce()
      quiesced.withLock { $0 = true }
    }
    world.run(for: .zero)
    let b = try world.node("b", [.cell(Counter.self)])
    let call = ask(b)
    world.run(for: .zero)
    #expect(call.answer.answer == nil)
    world.simulation.thaw(a.process)
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == ["cleanup"])
    #expect(!quiesced.withLock { $0 })
    world.run(for: .seconds(15))
    #expect(call.answer.answer == nil)
    #expect(b.worker.cell(counter).value() == 1)
    valve.open("cleanup")
    world.run(for: .zero)
    #expect(quiesced.withLock { $0 })
    a.worker.release()
    world.run(for: .seconds(1))
    #expect(try call.answer.answer?.get() == 11)
    #expect(call.answer.durable == 11)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func aPreStartHoldBeginsTheScanWithoutOrdinaryDiscovery(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Counter.self)], starts: false)
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    drain(a, in: world)
    let b = try world.node("b", [.cell(Counter.self), .cell(Auditor.self)], starts: false)
    let auditor = Auditor.ID("waiting")
    try world.client().send(auditor).record(23)
    let call = ask(b)
    world.run(for: .seconds(15))
    #expect(call.answer.answer == nil)
    #expect(b.worker.hasMail(for: auditor.recipient))
    a.worker.release()
    world.run(for: .seconds(1))
    #expect(try call.answer.answer?.get() == 11)
    #expect(b.worker.hasMail(for: auditor.recipient))
    b.worker.start()
    world.run(for: .seconds(1))
    #expect(!b.worker.hasMail(for: auditor.recipient))
    #expect(b.worker.cell(auditor).seen() == [23])
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func aHeldCallClaimsWhenTheDrainingHoldersLeaseExpires(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Counter.self)])
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    drain(a, in: world)
    let b = try world.node("b", [.cell(Counter.self)])
    let call = ask(b)
    world.run(for: .seconds(1))
    #expect(call.answer.answer == nil)
    world.simulation.kill(a.process)
    world.run(for: .seconds(11))
    #expect(try call.answer.answer?.get() == 11)
    #expect(call.answer.durable == 11)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func cancellingAHeldCallDoesNotRunItOrCancelAnotherCall(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Counter.self)])
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    drain(a, in: world)
    let b = try world.node("b", [.cell(Counter.self)])
    let cancelled = ask(b)
    let continuing = ask(b)
    world.run(for: .seconds(1))
    #expect(cancelled.answer.answer == nil)
    cancelled.task.cancel()
    world.run(for: .zero)
    #expect(throws: CancellationError.self) { try cancelled.answer.answer?.get() }
    #expect(cancelled.answer.durable == 1)
    #expect(continuing.answer.answer == nil)
    a.worker.release()
    world.run(for: .seconds(1))
    #expect(try continuing.answer.answer?.get() == 11)
    #expect(b.worker.cell(counter).value() == 11)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func quiescingTheCallerEvictsItsHeldCalls(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Counter.self)])
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    drain(a, in: world)
    let b = try world.node("b", [.cell(Counter.self)])
    let calls = [ask(b), ask(b)]
    world.run(for: .seconds(1))
    drain(b, in: world)
    for call in calls {
      #expect(throws: Evicted.self) { try call.answer.answer?.get() }
      #expect(call.answer.durable == 1)
    }
    a.worker.release()
    b.worker.release()
    world.run(for: .seconds(2))
    #expect(b.worker.cell(counter).value() == 1)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func aServingHolderStillRefusesACall(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Counter.self)])
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    let b = try world.node("b", [.cell(Counter.self)])
    let call = ask(b)
    world.run(for: .zero)
    #expect(throws: Evicted.self) { try call.answer.answer?.get() }
    #expect(call.answer.durable == 1)
  }

  @Test(arguments: [false, true], 1 ... 12 as ClosedRange<UInt64>)
  func aHeldCallIsEvictedWhenAnotherServingWorkerWinsTheClaim(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try world.node("a", [.cell(Counter.self)])
    a.worker.send(counter).add(1)
    world.run(for: .zero)
    drain(a, in: world)
    let b = try world.node("b", [.cell(Counter.self)])
    let held = ask(b)
    world.run(for: .seconds(1))
    #expect(held.answer.answer == nil)
    world.simulation.freeze(b.process)
    a.worker.release()
    let c = try world.node("c", [.cell(Counter.self)], starts: false)
    let winner = ask(c)
    world.run(for: .zero)
    #expect(try winner.answer.answer?.get() == 11)
    world.simulation.thaw(b.process)
    world.run(for: .seconds(1))
    #expect(throws: Evicted.self) { try held.answer.answer?.get() }
    #expect(held.answer.durable == 11)
    #expect(b.worker.cell(counter).value() == 11)
  }
}
