import Synchronization
import Testing
import Wuwei

@Cell
struct Counter {
  static let schema = ["CREATE TABLE counter (value INTEGER NOT NULL)", "INSERT INTO counter VALUES (0)"]

  func value() -> Int64 {
    db.one("SELECT value FROM counter")!.integer!
  }

  mutating func add(_ amount: Int64) throws {
    try db.execute("UPDATE counter SET value = value + ?", .integer(amount))
  }

  mutating func addThenPass(_ amount: Int64, _ label: String) throws {
    try add(amount)
    ctx.dependency(Tripwire.self).trip()
    let valve = ctx.dependency(Valve.self)
    ctx.emit { await valve.pass(label) }
  }

  mutating func addThenLook(_ amount: Int64) throws {
    try add(amount)
    let mirror = ctx.dependency(Mirror.self)
    ctx.emit { [id] in mirror.look(at: id) }
  }

  mutating func addThenFail(_ amount: Int64) throws {
    try add(amount)
    ctx.send(Auditor.ID("x")).record(100)
    throw Refused()
  }
}

struct Refused: Error {}

/// Writes down what a counter's durable value was when it looked.
@Cell
struct Auditor {
  static let schema = ["CREATE TABLE seen (value INTEGER NOT NULL)"]

  func seen() -> [Int64] {
    db.rows("SELECT value FROM seen").map { $0[0].integer! }
  }

  mutating func audit(_ counter: Counter.ID) throws {
    try record(ctx.cell(counter).value())
  }

  mutating func record(_ value: Int64) throws {
    try db.execute("INSERT INTO seen VALUES (?)", .integer(value))
  }
}

/// From inside an output, reads what the counter's durable state says.
final class Mirror: Sendable {
  let worker = Mutex<Worker?>(nil)
  let seen = Mutex<[Int64]>([])

  func look(at counter: Counter.ID) {
    let value = worker.withLock { $0! }.cell(counter).value()
    seen.withLock { $0.append(value) }
  }
}

/// Runs its action once, synchronously, from inside a call.
final class Tripwire: Sendable {
  private let action = Mutex<(@Sendable () -> Void)?>(nil)

  func arm(_ action: @escaping @Sendable () -> Void) {
    self.action.withLock { $0 = action }
  }

  func trip() {
    action.withLock { action in
      defer { action = nil }
      return action
    }?()
  }
}

@Suite struct CellTests {
  let world = World()
  let counter = Counter.ID("c")
  let valve = Valve()
  let tripwire = Tripwire()
  let mirror = Mirror()

  var dependencies: Dependencies {
    var dependencies = Dependencies()
    dependencies.register(valve)
    dependencies.register(tripwire)
    dependencies.register(mirror)
    return dependencies
  }

  func node(_ id: String) throws -> Node {
    try world.node(id, [.cell(Counter.self), .cell(Auditor.self)], dependencies: dependencies)
  }

  func value(_ worker: Worker) -> Int64 {
    worker.cell(counter).value()
  }

  @Test func callsCommitTheirWritesAndOutliveTheProcess() throws {
    let a = try node("a")
    let client = try world.client()
    client.send(counter).add(2)
    client.send(counter).add(3)
    world.run(for: .seconds(2))
    #expect(value(client) == 5)

    world.simulation.kill(a.process)
    _ = try node("b")
    client.send(counter).add(1)
    world.run(for: .seconds(15))
    #expect(value(client) == 6)
  }

  @Test func aCallReadsAnotherCellsDurableState() throws {
    _ = try node("a")
    let client = try world.client()
    let auditor = Auditor.ID("x")
    client.send(counter).add(4)
    world.run(for: .seconds(2))
    client.send(auditor).audit(counter)
    world.run(for: .seconds(2))
    #expect(client.cell(auditor).seen() == [4])
  }

  @Test func aReadOfACellThatNeverBootedSeesAFreshOne() throws {
    let client = try world.client()
    #expect(client.cell(Counter.ID("never")).value() == 0)
  }

  @Test func aCallThatThrowsRollsBackWhatItWroteAndSent() throws {
    _ = try node("a")
    let client = try world.client()
    client.send(counter).add(1)
    client.send(counter).addThenFail(5)
    world.run(for: .seconds(3))
    #expect(value(client) == 1)
    #expect(client.cell(Auditor.ID("x")).seen() == [])
  }

  @Test func anOutputSeesWhatCameBeforeItAsDurable() throws {
    let a = try node("a")
    mirror.worker.withLock { $0 = a.worker }
    let client = try world.client()
    client.send(counter).addThenLook(2)
    world.run(for: .seconds(2))
    client.send(counter).addThenLook(3)
    world.run(for: .seconds(2))
    #expect(mirror.seen.withLock { $0 } == [2, 5])
  }

  @Test func aPausedHolderLosesItsLeaseAndTheOutputsItHeld() throws {
    let a = try node("a")
    tripwire.arm { [world] in world.simulation.freeze(a.process) }
    try world.client().send(counter).addThenPass(10, "out")
    world.run(for: .seconds(2))
    let b = try node("b")
    world.run(for: .seconds(20))
    #expect(valve.waitingLabels == ["out"])

    valve.open("out")
    world.simulation.thaw(a.process)
    world.run(for: .seconds(5))
    #expect(valve.passedLabels == ["out"])
    #expect(value(b.worker) == 10)
  }

  @Test(arguments: 1 ... 12 as ClosedRange<UInt64>)
  func zeroAsyncCallsAreExactlyOnceUnderPausesAndCrashes(seed: UInt64) throws {
    let world = World(seed: seed)
    let a = try world.node("a", [.cell(Counter.self)])
    let b = try world.node("b", [.cell(Counter.self)])
    let client = try world.client()
    for step in 0 ..< 30 {
      if step == Int(seed % 10) { world.simulation.freeze(a.process) }
      if step == Int(seed % 10) + 6 { world.simulation.thaw(a.process) }
      if step == 20 + Int(seed % 5) {
        world.simulation.kill(b.process)
        _ = try world.node("c", [.cell(Counter.self)])
      }
      client.send(counter).add(1)
      world.run(for: .milliseconds(1500 + 300 * Int64((seed + UInt64(step)) % 7)))
    }
    world.run(for: .seconds(30))
    #expect(client.cell(counter).value() == 30)
  }
}
