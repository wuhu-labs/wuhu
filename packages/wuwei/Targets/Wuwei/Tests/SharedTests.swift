import Testing
import Wuwei

/// Keeps its entries in an owned table, which on the shared backend every ledger shares.
@Cell
struct Ledger {
  static let schema = ["CREATE TABLE ledger_entry (\(ownerColumn), amount INTEGER NOT NULL)"]

  func total() -> Int64 {
    db.one("SELECT coalesce(sum(amount), 0) FROM ledger_entry WHERE owner = cell()")!.integer!
  }

  mutating func add(_ amount: Int64) throws {
    try db.execute("INSERT INTO ledger_entry (amount) VALUES (?)", .integer(amount))
  }

  mutating func addThenFail(_ amount: Int64) throws {
    try add(amount)
    throw Refused()
  }

  mutating func forge(_ owner: String, _ amount: Int64) throws {
    try db.execute("INSERT INTO ledger_entry (owner, amount) VALUES (?, ?)", .text(owner), .integer(amount))
  }
}

/// Adds up `count` numbers, then credits a ledger with the sum.
@Job
struct Gather {
  static let schema = [
    "CREATE TABLE gather_number (\(ownerColumn), value INTEGER NOT NULL)",
    "CREATE TABLE gather_boot (\(ownerColumn), kind TEXT NOT NULL)",
  ]

  struct Params: Codable {
    let count: Int64
    let into: Ledger.ID
  }

  enum Message: Codable {
    case number(Int64)
  }

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO gather_boot (kind) VALUES ('create')")
  }

  static func hydrate(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO gather_boot (kind) VALUES ('hydrate')")
  }

  mutating func start() async throws -> Outcome {
    while true {
      let row = db.rows("SELECT count(*) AS count, coalesce(sum(value), 0) AS total FROM gather_number WHERE owner = cell()")[0]
      if row["count"].integer == ctx.params.count {
        return .done(sending: .add(row["total"].integer!), to: ctx.params.into.recipient)
      }
      guard case let .number(value)? = try await ctx.receive(within: .seconds(60)) else { return .hibernate }
      try db.execute("INSERT INTO gather_number (value) VALUES (?)", .integer(value))
    }
  }

  func boots() -> [String] {
    db.rows("SELECT kind FROM gather_boot WHERE owner = cell() ORDER BY rowid").map { $0[0].text! }
  }
}

enum Ticks: Socket {
  enum Outgoing: Sendable, Equatable {
    case missed([Int64])
    case tick(Int64)
  }
}

/// Ticks `1 ... count`, a second apart; a socket that attaches late first hears the ticks it missed.
@Job
struct Clock {
  typealias Params = Int64
  typealias Message = Never
  static let schema = ["CREATE TABLE clock_tick (\(ownerColumn), n INTEGER NOT NULL)"]

  mutating func start() async throws -> Outcome {
    while Int64(ticks().count) < ctx.params {
      let n = Int64(ticks().count) + 1
      try db.execute("INSERT INTO clock_tick (n) VALUES (?)", .integer(n))
      for socket in ctx.sockets(of: Ticks.self) {
        socket.send(.tick(n))
      }
      try await ctx.sleep(for: .seconds(1))
    }
    return .done
  }

  func attached(_ socket: SocketHandle<Ticks>) {
    socket.send(.missed(ticks()))
  }

  func ticks() -> [Int64] {
    db.rows("SELECT n FROM clock_tick WHERE owner = cell() ORDER BY n").map { $0[0].integer! }
  }
}

/// The same addressables on both backends, owned tables throughout.
@Suite struct SharedTests {
  let first = Ledger.ID("first")
  let second = Ledger.ID("second")
  let gather = Gather.ID("g")

  func node(_ id: String, in world: World) throws -> Node {
    try world.node(id, [.cell(Ledger.self), .job(Gather.self), .job(Clock.self)])
  }

  @Test(arguments: [false, true])
  func ownedRowsStayWithTheirCellAcrossAFailover(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try node("a", in: world)
    let client = try world.client()
    client.send(first).add(2)
    client.send(second).add(5)
    client.send(first).add(3)
    world.run(for: .seconds(2))
    #expect(client.cell(first).total() == 5)
    #expect(client.cell(second).total() == 5)

    world.simulation.kill(a.process)
    _ = try node("b", in: world)
    client.send(first).add(1)
    world.run(for: .seconds(15))
    #expect(client.cell(first).total() == 6)
    #expect(client.cell(second).total() == 5)
  }

  @Test(arguments: [false, true])
  func aCallThatThrowsUndoesItsWritesAndIsNotRetried(shared: Bool) throws {
    let world = World(shared: shared)
    _ = try node("a", in: world)
    let client = try world.client()
    client.send(first).add(1)
    client.send(first).addThenFail(5)
    world.run(for: .seconds(20))
    #expect(client.cell(first).total() == 1)
  }

  @Test(arguments: [false, true])
  func aCellCannotCreditAnotherCellsRows(shared: Bool) throws {
    let world = World(shared: shared)
    _ = try node("a", in: world)
    let client = try world.client()
    client.send(first).add(3)
    client.send(second).forge("first", 100)
    world.run(for: .seconds(2))
    #expect(client.cell(first).total() == 3)
    #expect(client.cell(second).total() == 0)
  }

  @Test(arguments: [false, true])
  func aJobIsCreatedOnceHydratedOnEveryBootAndRepliesWhenDone(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try node("a", in: world)
    try a.worker.create(gather, params: .init(count: 2, into: first))
    a.worker.send(.number(3), to: gather)
    world.run(for: .seconds(3))
    #expect(a.worker.job(gather).boots() == ["create", "hydrate"])

    world.simulation.kill(a.process)
    let b = try node("b", in: world)
    world.run(for: .seconds(15))
    b.worker.send(.number(4), to: gather)
    world.run(for: .seconds(3))
    #expect(b.worker.job(gather).boots() == ["create", "hydrate", "hydrate"])
    #expect(b.worker.cell(first).total() == 7)
  }

  @Test(arguments: [false, true])
  func aSocketThatAttachesLateHearsWhatItMissedFirst(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try node("a", in: world)
    let clock = Clock.ID("c")
    try a.worker.create(clock, params: 4)
    world.run(for: .milliseconds(2500))
    let client = Client<Ticks>()
    _ = try #require(a.worker.attach(Ticks.self, to: clock) { client.hear($0, durable: []) })
    world.run(for: .seconds(5))
    #expect(client.heard == [.frame(.missed([1, 2, 3])), .frame(.tick(4)), .closed])
  }
}
