import Synchronization
import Testing
@testable import Wuwei

private final class LossProbe: Sendable {
  let runs = Mutex(0)
  let deaths = Mutex(0)
  let rerun: @Sendable () -> Void
  init(rerun: @escaping @Sendable () -> Void) { self.rerun = rerun }
}

@Job private struct TransactionLossJob {
  enum Params: String, Codable { case direct, joined, fail }
  typealias Message = Never
  static let schema = ["CREATE TABLE loss_value (\(ownerColumn), n INTEGER UNIQUE)"]
  static let recipient = Ledger.ID("unhosted").recipient

  static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO loss_value (n) VALUES (0)")
  }

  mutating func start() async throws -> Outcome {
    try await ctx.effect {}
    let probe = ctx.dependency(LossProbe.self)
    let run = probe.runs.withLock { $0 += 1; return $0 }
    if run == 2 {
      #expect(values() == [0])
      probe.rerun()
      return .done(sending: .add(7), to: Self.recipient)
    }
    #expect(run == 1)
    try db.execute("INSERT INTO loss_value (n) VALUES (1)")
    ctx.send(.add(99), to: Self.recipient)
    let incarnation = db.access.incarnation
    do {
      switch ctx.params {
      case .direct: try db.execute("INSERT OR ROLLBACK INTO loss_value (n) VALUES (2), (0), (3)")
      case .joined:
        try incarnation.step {
          try incarnation.write("INSERT OR ROLLBACK INTO loss_value (n) VALUES (2), (0), (3)", []).get()
        }
      case .fail: try db.execute("INSERT OR FAIL INTO loss_value (n) VALUES (2), (0), (3)")
      }
    } catch is Evicted {
      #expect(incarnation.dead)
      probe.deaths.withLock { $0 += 1 }
    } catch is ConstraintViolation {
      #expect(!incarnation.dead)
    }
    return .done
  }

  func values() -> [Int64] {
    db.rows("SELECT n FROM loss_value ORDER BY n").map { $0[0].integer! }
  }
}

@Cell private struct TransactionLossCell {
  static let schema = ["CREATE TABLE loss_cell (\(ownerColumn), n INTEGER UNIQUE)"]
  mutating func rollback() throws {
    try db.execute("INSERT INTO loss_cell (n) VALUES (1)")
    ctx.send(Ledger.ID("unhosted")).add(99)
    do { try db.execute("INSERT OR ROLLBACK INTO loss_cell (n) VALUES (1)") }
    catch {}
  }
}

private func runLoss(shared: Bool, mode: TransactionLossJob.Params, dies: Bool, values: [Int64]) throws {
  let world = World(shared: shared)
  let node = try world.node("loss", [.job(TransactionLossJob.self)], starts: false)
  let worker = node.worker
  let id = TransactionLossJob.ID("job")
  let probe = LossProbe(rerun: {
    #expect(!worker.hasMail(for: TransactionLossJob.recipient))
    let phase = try! worker.store.read { try $0.rows("SELECT phase FROM wuwei_job WHERE address = ?", .text(id.description))[0][0].text! }
    #expect(phase == "live")
  })
  worker.provide(probe)
  try worker.create(id, params: mode)
  world.run(for: .milliseconds(50))
  #expect(probe.deaths.withLock { $0 } == (dies ? 1 : 0))
  #expect(probe.runs.withLock { $0 } == (dies ? 2 : 1))
  #expect(worker.job(id).values() == values)
  let mail = try worker.store.read { try $0.rows("SELECT payload FROM wuwei_mail WHERE recipient = ?", .text(TransactionLossJob.recipient.raw)) }
  #expect(mail.count == 1)
  let message = try decode(Ledger.Message.self, from: mail[0][0].blob!)
  switch message {
  case let .add(amount): #expect(amount == (dies ? 7 : 99))
  default: Issue.record("unexpected mail")
  }
}

@Suite struct TransactionLossTests {
  @Test func aSharedStatementThatEndsTheTransactionKillsTheIncarnationBeforeMailOrDone() throws {
    try runLoss(shared: true, mode: .direct, dies: true, values: [0])
  }

  @Test(arguments: [false, true])
  func losingAStepSavepointKillsTheIncarnationBeforeMailOrDone(shared: Bool) throws {
    try runLoss(shared: shared, mode: .joined, dies: true, values: [0])
  }

  @Test func aLayeredImplicitRollbackKeepsEarlierStatements() throws {
    try runLoss(shared: false, mode: .direct, dies: false, values: [0, 1])
  }

  @Test(arguments: [false, true])
  func failConflictPolicyKeepsTheRowsBeforeTheFailure(shared: Bool) throws {
    try runLoss(shared: shared, mode: .fail, dies: false, values: [0, 1, 2])
  }

  @Test func aSharedCellWhoseStatementEndsTheTransactionTrapsAsAStorageFailure() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      let world = World(shared: true)
      let node = try world.node("cell", [.cell(TransactionLossCell.self)], starts: false)
      node.worker.task {
        do { try await node.worker.call(TransactionLossCell.ID("cell")) { try $0.rollback() } }
        catch { Issue.record(error) }
      }
      world.run(for: .milliseconds(50))
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a failed statement ended its transaction"))
  }
}

private final class BootLossProbe: Sendable {
  let creates = Mutex(0)
  let hydrates = Mutex(0)
  let starts = Mutex(0)
}

private final class BootLossDatabase: SharedDatabase {
  let file: FileDatabase
  let fail = Mutex(true)
  init(path: String) throws { file = try FileDatabase(path: path, synchronous: false) }
  func write(_ body: (OpaquePointer, AnyObject?) throws -> Void) throws { try file.write(body) }
  func read(_ body: (OpaquePointer) throws -> Void) throws { try file.read(body) }
  func begin() throws -> any SharedTransaction { try file.begin() }
  func execute(_ sql: String, _: [Value], on _: AnyObject?) throws -> Bool {
    if sql == "INSERT INTO boot_loss (n) VALUES (9)", fail.withLock({ let first = $0; $0 = false; return first }) {
      throw SQLiteError(code: 10, message: "injected boot storage failure")
    }
    return false
  }
}

@Job private struct BootLossJob {
  struct Params: Codable, Sendable {
    var hydrate: Bool
    var storage: Bool
    var caught: Bool
    static var cases: [Self] {
      [false, true].flatMap { hydrate in [false, true].flatMap { storage in [false, true].map { Self(hydrate: hydrate, storage: storage, caught: $0) } } }
    }
  }

  typealias Message = Never
  static let schema = ["CREATE TABLE boot_loss (\(ownerColumn), n INTEGER UNIQUE)"]

  static func create(ctx: inout JobContext<Self>) throws {
    let attempt = ctx.dependency(BootLossProbe.self).creates.withLock { $0 += 1; return $0 }
    #expect(ctx.db.rows("SELECT n FROM boot_loss").isEmpty)
    try ctx.db.execute("INSERT INTO boot_loss (n) VALUES (0)")
    if !ctx.params.hydrate, attempt == 1 { try lose(ctx: &ctx) }
  }

  static func hydrate(ctx: inout JobContext<Self>) throws {
    let attempt = ctx.dependency(BootLossProbe.self).hydrates.withLock { $0 += 1; return $0 }
    #expect(ctx.db.rows("SELECT n FROM boot_loss ORDER BY n").map { $0[0].integer! } == [0])
    if ctx.params.hydrate, attempt == 1 { try lose(ctx: &ctx) }
  }

  static func lose(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO boot_loss (n) VALUES (1)")
    ctx.send(.add(99), to: TransactionLossJob.recipient)
    do {
      try ctx.db.execute(ctx.params.storage ? "INSERT INTO boot_loss (n) VALUES (9)" : "INSERT OR ROLLBACK INTO boot_loss (n) VALUES (1)")
      Issue.record("the failing statement returned")
    } catch is Evicted {
      #expect(!ctx.db.access.incarnation.dead)
      guard ctx.params.caught else { throw Evicted(address: ctx.id.description) }
      do {
        try ctx.db.execute("INSERT INTO boot_loss (n) VALUES (2)")
        Issue.record("a failed boot continued writing")
      } catch is Evicted {}
    }
  }

  mutating func start() async throws -> Outcome {
    ctx.dependency(BootLossProbe.self).starts.withLock { $0 += 1 }
    return .done(sending: .add(7), to: TransactionLossJob.recipient)
  }
}

extension TransactionLossTests {
  @Test(arguments: BootLossJob.Params.cases)
  fileprivate func bootStorageFailureReleasesTheWriterBeforeRemovingAndRepoking(params: BootLossJob.Params) throws {
    let world = World(shared: true)
    let database = try BootLossDatabase(path: world.path)
    let worker = Worker(id: "boot-loss", storage: .shared(database), scheduler: world.simulation.spawn(), registrations: [.job(BootLossJob.self)])
    let probe = BootLossProbe()
    worker.provide(probe)
    let id = BootLossJob.ID("job")
    try worker.create(id, params: params)
    world.run(for: .milliseconds(50))
    #expect(probe.creates.withLock { $0 } == (params.hydrate ? 1 : 2))
    #expect(probe.hydrates.withLock { $0 } == (params.hydrate ? 2 : 1))
    #expect(probe.starts.withLock { $0 } == 1)
    #expect(worker.job(id).db.rows("SELECT n FROM boot_loss ORDER BY n").map { $0[0].integer! } == [0])
    let mail = try worker.store.read { try $0.rows("SELECT payload FROM wuwei_mail WHERE recipient = ?", .text(TransactionLossJob.recipient.raw)) }
    #expect(mail.count == 1)
    switch try decode(Ledger.Message.self, from: mail[0][0].blob!) {
    case let .add(amount): #expect(amount == 7)
    default: Issue.record("unexpected boot mail")
    }
    let phase = try worker.store.read { try $0.rows("SELECT phase FROM wuwei_job WHERE address = ?", .text(id.description))[0][0].text! }
    #expect(phase == "done")
  }
}
