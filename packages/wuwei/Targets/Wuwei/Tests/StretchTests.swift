import Synchronization
import Testing
@testable import Wuwei

private struct StretchSnapshot: Sendable, Equatable {
  var values: [Int64]
  var mail: Int
  var phase: String?
}

private final class StretchDatabase: SharedDatabase {
  let file: FileDatabase
  let commits = Mutex<[StretchSnapshot]>([])

  init(path: String) throws { file = try FileDatabase(path: path, synchronous: false) }

  static func snapshot(_ handle: OpaquePointer) throws -> StretchSnapshot? {
    let db = Connection(borrowing: handle)
    guard try !db.rows("SELECT 1 FROM sqlite_master WHERE name = 'stretch_value'").isEmpty else { return nil }
    return try StretchSnapshot(
      values: db.rows("SELECT n FROM stretch_value ORDER BY rowid").map { $0[0].integer! },
      mail: Int(db.rows("SELECT count(*) FROM wuwei_mail")[0][0].integer!),
      phase: db.rows("SELECT phase FROM wuwei_job LIMIT 1").first?[0].text,
    )
  }

  func write(label: String = "writer.write", _ body: (OpaquePointer) throws -> Void) throws {
    var snapshot: StretchSnapshot?
    try file.write(label: label) { handle in
      try body(handle)
      snapshot = try Self.snapshot(handle)
    }
    if let snapshot { commits.withLock { $0.append(snapshot) } }
  }

  func begin(label: String = "writer.begin") throws -> any SharedTransaction {
    StretchTransaction(base: try file.begin(label: label), database: self)
  }

  func beginRead() throws -> any SharedReadTransaction { try file.beginRead() }
}

private final class StretchTransaction: SharedTransaction {
  let base: any SharedTransaction
  let database: StretchDatabase
  init(base: any SharedTransaction, database: StretchDatabase) { self.base = base; self.database = database }
  func access<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T { try base.access(body) }
  func commit() throws {
    let snapshot = try base.access { handle in try StretchDatabase.snapshot(handle) }
    try base.commit()
    if let snapshot { database.commits.withLock { $0.append(snapshot) } }
  }

  func rollback() { base.rollback() }
}

private struct StretchProbe: Sendable {
  let run: @Sendable () -> Void
}

@Job private struct StretchJob {
  enum Params: String, Codable { case pair, send, throwing, constraint, read, effect, prepare }
  typealias Message = Never
  static let schema = ["CREATE TABLE stretch_value (\(ownerColumn), n INTEGER NOT NULL UNIQUE)"]

  mutating func start() async throws -> Outcome {
    try db.execute("INSERT INTO stretch_value (n) VALUES (1)")
    switch ctx.params {
    case .pair:
      try await ctx.sleep(for: .zero)
      try db.execute("INSERT INTO stretch_value (n) VALUES (2)")
    case .send:
      ctx.send(Ledger.ID("receiver")).add(1)
    case .throwing:
      throw Refused()
    case .constraint:
      do { try db.execute("INSERT INTO stretch_value (n) VALUES (1)") }
      catch is ConstraintViolation {}
      try db.execute("INSERT INTO stretch_value (n) VALUES (2)")
    case .read:
      #expect(db.one("SELECT n FROM stretch_value WHERE owner = cell()") == 1)
      #expect(ctx.job(id).db.one("SELECT n FROM stretch_value WHERE owner = cell()") == 1)
    case .effect:
      try await ctx.sleep(for: .zero)
      let probe = ctx.dependency(StretchProbe.self)
      try await ctx.effect { probe.run() }
      try db.execute("INSERT INTO stretch_value (n) VALUES (2)")
    case .prepare:
      #expect(ctx.cell(Ledger.ID("unregistered")).total() == 0)
    }
    return .done
  }
}

@Suite struct StretchTests {
  @Test(arguments: [StretchJob.Params.pair, .send, .throwing, .constraint, .read, .effect, .prepare])
  fileprivate func aWritingStretchCommitsAsOneTransaction(mode: StretchJob.Params) throws {
    let world = World(shared: true)
    let database = try StretchDatabase(path: world.path)
    let process = world.simulation.spawn()
    let worker = Worker(id: "stretch", storage: .shared(database), scheduler: process, registrations: [.job(StretchJob.self)])
    let effects = Mutex(0)
    worker.provide(StretchProbe(run: {
      Lane.preconditionNoWriter("run a foreign effect before committing")
      do {
        try database.read { handle in
          let reader = Connection(borrowing: handle)
          let values = try reader.rows("SELECT n FROM stretch_value ORDER BY n").map { $0[0].integer! }
          #expect(values == [1])
        }
      } catch { Issue.record(error) }
      #expect(database.commits.withLock { $0.last?.values } == [1])
      effects.withLock { $0 += 1 }
    }))
    try worker.create(StretchJob.ID("job"), params: mode)
    world.run(for: .milliseconds(10))
    let snapshots = database.commits.withLock { $0 }
    let written = snapshots.filter { !$0.values.isEmpty }
    #expect(!written.isEmpty)
    switch mode {
    case .pair, .constraint:
      #expect(written.count == 1)
      #expect(written[0].values == [1, 2])
      #expect(written[0].phase == "done")
    case .send:
      #expect(written.count == 1)
      #expect(written[0].values == [1])
      #expect(written[0].mail == 1)
    case .throwing:
      #expect(written.count == 1)
      #expect(written[0].values == [1])
      #expect(written[0].phase == "live")
    case .read, .prepare:
      #expect(written.count == 1)
      #expect(written[0].values == [1])
    case .effect:
      #expect(effects.withLock { $0 } == 1)
      #expect(written.map(\.values) == [[1], [1, 2]])
    }
  }
}
