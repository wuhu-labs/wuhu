import Synchronization
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

@Job
struct CancellationAnswer {
  static let schema = ["CREATE TABLE answer (value TEXT NOT NULL)"]
  typealias Message = Never

  struct Params: Codable {
    let effect: Bool
    let replyTo: Recipient<Sink.Message>
  }

  mutating func start() async throws -> Outcome {
    try db.execute("INSERT INTO answer VALUES ('started')")
    do {
      if ctx.params.effect {
        let valve = ctx.dependency(Valve.self)
        try await ctx.effect { try await valve.wait("answer") }
      } else {
        _ = try await ctx.receive(within: .seconds(60))
      }
    } catch is CancellationError {
      try db.execute("INSERT INTO answer VALUES ('cancelled')")
      return .done(sending: .total(1), to: ctx.params.replyTo)
    }
    return .notDone
  }

  func answers() -> [String] {
    db.rows("SELECT value FROM answer").map { $0[0].text! }
  }
}

/// Races a valve for a message: the body finishes under cancellation when `finishes`, and is ended by it otherwise.
@Job
struct CancelledRace {
  static let schema = ["CREATE TABLE answer (value TEXT NOT NULL)"]

  struct Params: Codable {
    let finishes: Bool
  }

  enum Message: Codable, Equatable {
    case stop
  }

  mutating func start() async throws -> Outcome {
    let valve = ctx.dependency(Valve.self)
    let finishes = ctx.params.finishes
    do {
      switch try await ctx.race({ _, _ in
        if finishes { await valve.pass("work") } else { try await valve.wait("work") }
        return 42
      }, until: { $0 == .stop }) {
      case let .finished(value): try db.execute("INSERT INTO answer VALUES (?)", .text("finished \(value)"))
      case .message: try db.execute("INSERT INTO answer VALUES ('stopped')")
      }
    } catch is CancellationError {
      try db.execute("INSERT INTO answer VALUES ('cancelled')")
    }
    return .done
  }

  func answers() -> [String] {
    db.rows("SELECT value FROM answer").map { $0[0].text! }
  }
}

/// Holds before its race and inside the raced body: what the mail a quiesce leaves behind is about.
@Job
struct BufferedMailRace {
  static let schema = ["CREATE TABLE log (text TEXT NOT NULL)"]

  struct Params: Codable {
    let enter: String
    let work: String
  }

  enum Message: Codable, Equatable, Sendable {
    case stop
    case noise
  }

  mutating func start() async throws -> Outcome {
    let valve = ctx.dependency(Valve.self)
    let enter = ctx.params.enter
    let work = ctx.params.work
    try await ctx.effect { await valve.pass(enter) }
    switch try await ctx.race({ _, _ in
      await valve.pass(work)
      return 42
    }, until: { $0 == .stop }) {
    case .finished: try db.execute("INSERT INTO log VALUES ('finished')")
    case .message: try db.execute("INSERT INTO log VALUES ('stopped')")
    }
    return .notDone
  }

  func log() -> [String] {
    db.rows("SELECT text FROM log").map { $0[0].text! }
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

  @Test(arguments: [false, true], [false, true])
  func aCancelledStartCommitsItsLastWriteAndAnswer(shared: Bool, effect: Bool) throws {
    let world = World(shared: shared)
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(CancellationAnswer.self)], dependencies: dependencies)
    let job = CancellationAnswer.ID("answer")
    try a.worker.create(job, params: .init(effect: effect, replyTo: sink.recipient))
    world.run(for: .seconds(1))
    #expect(a.worker.job(job).answers() == ["started"])
    if effect { #expect(valve.waitingLabels == ["answer"]) }

    let quiesced = Mutex(false)
    Task(executorPreference: a.process) {
      await a.worker.quiesce()
      #expect(a.worker.job(job).answers() == ["started", "cancelled"])
      #expect(a.worker.hasMail(for: sink.recipient))
      quiesced.withLock { $0 = true }
    }
    world.run(for: .seconds(1))
    #expect(quiesced.withLock { $0 })
    #expect(valve.waitingLabels.isEmpty)
    let b = try world.node("b", [.job(CancellationAnswer.self), .cell(Sink.self)], starts: false)
    #expect(b.worker.job(job).answers() == ["started", "cancelled"])
    #expect(b.worker.hasMail(for: sink.recipient))
    a.worker.release()
    b.worker.start()
    world.run(for: .seconds(15))
    #expect(b.worker.cell(sink).totals() == [1])
    #expect(b.worker.job(job).answers() == ["started", "cancelled"])
    #expect(!b.worker.hasMail(for: sink.recipient))
  }

  @Test(arguments: [false, true], [false, true])
  func aRaceUnderCancellationEndsWithTheBody(shared: Bool, finishes: Bool) throws {
    let world = World(shared: shared)
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(CancelledRace.self)], dependencies: dependencies)
    let job = CancelledRace.ID("race")
    try a.worker.create(job, params: .init(finishes: finishes))
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == ["work"])

    let quiesced = Mutex(false)
    Task(executorPreference: a.process) {
      await a.worker.quiesce()
      quiesced.withLock { $0 = true }
    }
    world.run(for: .milliseconds(100))
    valve.open("work")
    world.run(for: .seconds(1))
    #expect(quiesced.withLock { $0 })
    #expect(a.worker.job(job).answers() == [finishes ? "finished 42" : "cancelled"])
  }

  @Test(arguments: [BufferedMailRace.Message.stop, .noise])
  func aCancelledRaceLeavesBufferedMailForTheNextStart(message: BufferedMailRace.Message) throws {
    let world = World()
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(BufferedMailRace.self)], dependencies: dependencies)
    let job = BufferedMailRace.ID("mail")
    try a.worker.create(job, params: .init(enter: "enter", work: "work"))
    world.run(for: .seconds(1))
    #expect(valve.waitingLabels == ["enter"])

    a.worker.send(message, to: job)
    world.run(for: .milliseconds(10))

    let quiesced = Mutex(false)
    Task(executorPreference: a.process) {
      await a.worker.quiesce()
      quiesced.withLock { $0 = true }
    }
    world.run(for: .milliseconds(100))
    valve.open("enter")
    world.run(for: .milliseconds(100))
    valve.open("work")
    world.run(for: .seconds(1))
    #expect(quiesced.withLock { $0 })
    #expect(a.worker.job(job).log() == ["finished"])
    #expect(a.worker.hasMail(for: job.recipient))

    a.worker.release()
    let b = try world.node("b", [.job(BufferedMailRace.self)], dependencies: dependencies, starts: false)
    #expect(b.worker.hasMail(for: job.recipient))
    b.worker.start()
    world.run(for: .seconds(1))
    valve.open("enter")
    world.run(for: .milliseconds(100))
    valve.open("work")
    world.run(for: .seconds(15))
    #expect(!b.worker.hasMail(for: job.recipient))
    #expect(b.worker.job(job).log() == ["finished", message == .stop ? "stopped" : "finished"])
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
