import Testing
import Wuwei

/// Rings at every time it was set to. Its next wake looks only ahead, so a time it missed while nobody held it rings through the wake time recorded for the scan.
@Cell
struct Alarm {
  static let schema = ["CREATE TABLE due (at INTEGER NOT NULL)", "CREATE TABLE rang (at INTEGER NOT NULL)"]

  func rang() -> [Int64] {
    db.rows("SELECT at FROM rang ORDER BY at").map { $0[0].integer! }
  }

  func nextWake() -> Instant? {
    db.one("SELECT MIN(at) FROM due WHERE at > ?", .integer(ctx.now.milliseconds))!.integer.map(Instant.init(milliseconds:))
  }

  mutating func set(_ at: Instant) throws {
    try db.execute("INSERT INTO due VALUES (?)", .integer(at.milliseconds))
  }

  mutating func wake() throws {
    let now = ctx.now.milliseconds
    try db.execute("INSERT INTO rang SELECT at FROM due WHERE at <= ?", .integer(now))
    try db.execute("DELETE FROM due WHERE at <= ?", .integer(now))
  }
}

/// Rings at the time it ran, not the time it was due: a wake handed to the next incarnation at once is told apart from one a later scan re-homes.
@Cell
struct Tick {
  static let schema = ["CREATE TABLE due (at INTEGER NOT NULL)", "CREATE TABLE rang (at INTEGER NOT NULL)"]

  func rang() -> [Int64] {
    db.rows("SELECT at FROM rang ORDER BY at").map { $0[0].integer! }
  }

  func nextWake() -> Instant? {
    db.one("SELECT MIN(at) FROM due WHERE at > ?", .integer(ctx.now.milliseconds))!.integer.map(Instant.init(milliseconds:))
  }

  mutating func set(_ at: Instant) throws {
    try db.execute("INSERT INTO due VALUES (?)", .integer(at.milliseconds))
  }

  mutating func wake() throws {
    let now = ctx.now.milliseconds
    try db.execute("INSERT INTO rang SELECT ? FROM due WHERE at <= ?", .integer(now), .integer(now))
    try db.execute("DELETE FROM due WHERE at <= ?", .integer(now))
  }
}

@Suite struct WakeTests {
  let alarm = Alarm.ID("a")
  let tick = Tick.ID("t")

  @Test(arguments: [false, true])
  func aCellWakesWhenItsNextWakeComes(shared: Bool) throws {
    let world = World(shared: shared)
    _ = try world.node("a", [.cell(Alarm.self)])
    let client = try world.client()
    let start = world.simulation.now
    client.send(alarm).set(start + .seconds(3))
    client.send(alarm).set(start + .seconds(8))
    world.run(for: .seconds(2))
    #expect(client.cell(alarm).rang() == [])
    world.run(for: .seconds(2))
    #expect(client.cell(alarm).rang() == [(start + .seconds(3)).milliseconds])
    world.run(for: .seconds(5))
    #expect(client.cell(alarm).rang() == [(start + .seconds(3)).milliseconds, (start + .seconds(8)).milliseconds])
  }

  @Test(arguments: [false, true])
  func aWakeOutlivesEvictionAndItsHoldersDeath(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try world.node("a", [.cell(Alarm.self)])
    let client = try world.client()
    let start = world.simulation.now
    client.send(alarm).set(start + .seconds(20))
    client.send(alarm).set(start + .seconds(40))
    world.run(for: .seconds(25))
    #expect(client.cell(alarm).rang() == [(start + .seconds(20)).milliseconds])

    world.simulation.kill(a.process)
    _ = try world.node("b", [.cell(Alarm.self)])
    world.run(for: .seconds(20))
    #expect(client.cell(alarm).rang() == [(start + .seconds(20)).milliseconds, (start + .seconds(40)).milliseconds])
  }

  /// No scan is running, so only the wake handing itself on can run it after the eviction.
  @Test(arguments: [false, true])
  func aWakeThatFiresAfterItsCellWasEvictedIsHandedToTheNextIncarnation(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try world.node("a", [.cell(Tick.self)], starts: false)
    let start = world.simulation.now
    a.worker.send(tick).set(start + .milliseconds(5500))
    world.run(for: .seconds(6))
    #expect(a.worker.cell(tick).rang() == [(start + .milliseconds(5500)).milliseconds])
  }
}
