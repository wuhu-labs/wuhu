import Testing
import Wuwei

/// What a tally says, to whoever takes it among its own messages.
enum Tallied: Codable {
  case total(Int64)
}

/// Adds up the numbers it receives until it has `count` of them, then reports the sum and is done.
@Job
struct Tally {
  static let schema = ["CREATE TABLE number (value INTEGER NOT NULL)", "CREATE TABLE boot (kind TEXT NOT NULL)"]

  struct Params: Codable {
    let count: Int64
    let replyTo: Recipient<Tallied>
  }

  enum Message: Codable {
    case number(Int64)
  }

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO boot VALUES ('create')")
  }

  static func hydrate(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO boot VALUES ('hydrate')")
  }

  mutating func start() async throws -> Outcome {
    while true {
      let row = db.rows("SELECT count(*) AS count, coalesce(sum(value), 0) AS total FROM number")[0]
      if row["count"].integer == ctx.params.count {
        return .done(sending: .total(row["total"].integer!), to: ctx.params.replyTo)
      }
      guard case let .number(value)? = try await ctx.receive(within: .seconds(60)) else { return .hibernate }
      try db.execute("INSERT INTO number VALUES (?)", .integer(value))
    }
  }

  func boots() -> [String] {
    db.rows("SELECT kind FROM boot").map { $0["kind"].text! }
  }
}

@Cell
struct Sink {
  static let schema = ["CREATE TABLE total (value INTEGER NOT NULL)"]

  func totals() -> [Int64] {
    db.rows("SELECT value FROM total").map { $0[0].integer! }
  }

  mutating func total(_ value: Int64) throws {
    try db.execute("INSERT INTO total VALUES (?)", .integer(value))
  }

  mutating func reset() throws {
    try db.execute("DELETE FROM total")
  }
}

/// Waits for work it cannot finish alone, unless told to stop first.
@Job
struct Racer {
  typealias Params = Int64
  static let schema = ["CREATE TABLE result (text TEXT NOT NULL)"]

  enum Message: Codable, Equatable {
    case stop
    case noise
  }

  mutating func start() async throws -> Outcome {
    let valve = ctx.dependency(Valve.self)
    switch try await ctx.race({ _, _ in try await valve.wait("work") }, until: { $0 == .stop }) {
    case .finished: try db.execute("INSERT INTO result VALUES ('worked')")
    case .message: try db.execute("INSERT INTO result VALUES ('stopped')")
    }
    return .done
  }

  func results() -> [String] {
    db.rows("SELECT text FROM result").map { $0[0].text! }
  }
}

@Suite struct JobTests {
  let world = World()
  let tally = Tally.ID("t")
  let sink = Sink.ID("s")

  func node(_ id: String) throws -> Node {
    try world.node(id, [.job(Tally.self), .cell(Sink.self)])
  }

  func boots(_ worker: Worker) -> [String] {
    worker.job(tally).boots()
  }

  @Test func aJobRepliesAndIsDoneForGood() throws {
    let a = try node("a")
    try a.worker.create(tally, params: .init(count: 2, replyTo: sink.recipient.retyped()))
    a.worker.send(.number(3), to: tally)
    a.worker.send(.number(4), to: tally)
    world.run(for: .seconds(3))
    #expect(a.worker.cell(sink).totals() == [7])

    try a.worker.create(tally, params: .init(count: 0, replyTo: sink.recipient.retyped()))
    world.run(for: .seconds(3))
    #expect(a.worker.cell(sink).totals() == [7])
  }

  @Test func createRunsOnceAndHydrateOnEveryBoot() throws {
    let a = try node("a")
    try a.worker.create(tally, params: .init(count: 2, replyTo: sink.recipient.retyped()))
    a.worker.send(.number(1), to: tally)
    world.run(for: .seconds(3))
    #expect(boots(a.worker) == ["create", "hydrate"])

    world.simulation.kill(a.process)
    let b = try node("b")
    world.run(for: .seconds(15))
    #expect(boots(b.worker) == ["create", "hydrate", "hydrate"])

    b.worker.send(.number(2), to: tally)
    world.run(for: .seconds(3))
    #expect(b.worker.cell(sink).totals() == [3])
  }

  @Test func aRacedEffectThatFinishesFirstWinsOverMessagesThatDoNotStopIt() throws {
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(Racer.self)], dependencies: dependencies)
    let racer = Racer.ID("r")
    try a.worker.create(racer, params: 0)
    a.worker.send(.noise, to: racer)
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == ["work"])
    valve.open("work")
    world.run(for: .seconds(1))
    a.worker.send(.stop, to: racer)
    world.run(for: .seconds(1))
    #expect(a.worker.job(racer).results() == ["worked"])
  }

  @Test func aMessageThatComesFirstCancelsTheRacedEffect() throws {
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(Racer.self)], dependencies: dependencies)
    let racer = Racer.ID("r")
    try a.worker.create(racer, params: 0)
    world.run(for: .seconds(1))
    a.worker.send(.stop, to: racer)
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == [])
    #expect(a.worker.job(racer).results() == ["stopped"])
  }

  @Test func aHibernatingJobWakesOnMailAndResumesFromItsTables() throws {
    let a = try node("a")
    try a.worker.create(tally, params: .init(count: 3, replyTo: sink.recipient.retyped()))
    a.worker.send(.number(5), to: tally)
    world.run(for: .seconds(120))
    #expect(boots(a.worker) == ["create", "hydrate"])

    a.worker.send(.number(6), to: tally)
    world.run(for: .seconds(3))
    #expect(boots(a.worker) == ["create", "hydrate", "hydrate"])

    a.worker.send(.number(7), to: tally)
    world.run(for: .seconds(3))
    #expect(a.worker.cell(sink).totals() == [18])
  }
}
