#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dispatch
import GRDB
import GRDBSQLite
import Logging
import SessionDomain
import SpaceSQL
import Synchronization
import Wuwei

/// The space's wuwei runtime: one worker on the shared backend over the space's own database, hosting the kinds of every module of the space, on the date and clock injected where it is first asked for.
final class SpaceRuntime: Sendable {
  var machineBuffers: MachineBuffers {
    _ = worker()
    return running.withLock { $0!.buffers }
  }

  private let writer: any DatabaseWriter
  private let observations: ObservationSources
  private let documents: Documents
  private let log: Logger
  /// Held while a worker is made, which writes — and only there: the writer's commit hooks run inside a write, so no lock they take may be held across one.
  private let database = Mutex<WuweiDatabase?>(nil)
  /// The worker this space hosts and its scheduler; a commit hook poking a cell takes it for the length of a lock.
  private let running = Mutex<(worker: Worker, scheduler: DependencyScheduler, buffers: MachineBuffers)?>(nil)
  /// Whether the space is closing, read and set for the length of a lock only: closing under the same lock a worker is handed out under keeps the two atomic without holding it across the work of making one.
  private let closing = Mutex(false)

  init(writer: any DatabaseWriter, observations: ObservationSources, documents: Documents, log: Logger) {
    self.writer = writer
    self.observations = observations
    self.documents = documents
    self.log = log
  }

  func worker() -> Worker {
    guard let worker = hosted() else { preconditionFailure("the space is closing: it makes no worker") }
    return worker
  }

  /// The space's worker for an observation: made if the space has none yet, nil once the space is closing.
  func observing() -> Worker? {
    hosted()
  }

  /// The worker, made on first use; nil once the space is closing. `database` alone serializes the making, never a lock a commit hook takes: the making waits for the writer.
  private func hosted() -> Worker? {
    database.withLock { database in
      if let running = running.withLock({ $0 }) { return running.worker }
      guard !closing.withLock({ $0 }) else { return nil }
      if database == nil {
        do { database = try WuweiDatabase(writer: writer, log: log) } catch { preconditionFailure("the space database took no reader: \(error)") }
      }
      let scheduler = DependencyScheduler()
      // A worker retakes a lease held under its own id at once, so two processes on one database never share an id.
      let worker = Worker(id: "space-\(UUID().uuidString.lowercased())", storage: .shared(database!), scheduler: scheduler, registrations: [.cell(MachineCell.self), .cell(GroupCell.self), .cell(SpaceCell.self), .cell(PersonCell.self), .cell(ConversationCell.self), .cell(DocumentCell.self), .job(ObservationJob.self)])
      let buffers = MachineBuffers(worker: worker.id)
      worker.provide(buffers)
      worker.provide(observations)
      worker.provide(documents)
      do { try worker.create(ObservationJob.address, params: ObservationJob.Params()) } catch { preconditionFailure("the observation job was not created: \(error)") }
      running.withLock { $0 = (worker, scheduler, buffers) }
      return worker
    }
  }

  /// Has the session's cell look at its mail, after the write that posted it commits. Without a worker, or lost, a worker's scan finds the mail.
  func poke(_ session: SessionID) {
    running.withLock { $0?.worker }?.poke(Recipient<SessionMail>(kind: SessionMail.kind, key: session.rawValue))
  }

  func poke<Message>(_ recipient: Recipient<Message>) {
    running.withLock { $0?.worker }?.poke(recipient)
  }

  /// The same for a person's cell.
  func poke(person: String) {
    running.withLock { $0?.worker }?.poke(PersonCell.ID(person).recipient)
  }

  func quiesce() async {
    guard let running = running.withLock({ $0 }) else { return }
    await running.worker.quiesce()
  }

  /// The first act of closing. Waiting on `database` lets a making already under way settle, so the worker it installs is this space's to stop; then closing is set under the lock a worker is handed out under, and none is made after it.
  func beginClosing() {
    database.withLock { _ in closing.withLock { $0 = true } }
  }

  func stop() async {
    let stopped = running.withLock { $0 }
    guard let stopped else { return }
    await stopped.worker.quiesce()
    stopped.worker.release()
    stopped.scheduler.stop()
    running.withLock { running in
      if running?.worker === stopped.worker { running = nil }
    }
  }

  func close() throws {
    try database.withLock { try $0?.close() }
  }
}

extension Space {
  public nonisolated var machineBuffers: MachineBuffers { runtime.machineBuffers }

  /// The space's one worker, which a module gives its kinds and clients before `start`. After `stopWorker` the next one is new, as after a restart of the process.
  public nonisolated var worker: Worker {
    runtime.worker()
  }

  public nonisolated func quiesceWorker() async {
    await runtime.quiesce()
  }

  /// Quiesces the worker, ends its timers and releases its leases.
  public nonisolated func stopWorker() async {
    await runtime.stop()
  }
}

/// Which reader a read takes next; a struct cannot hold the counter itself.
private final class ReaderTurn: Sendable {
  let next = Atomic<UInt64>(0)
}

struct WuweiDatabase: SharedDatabase {
  let writer: any DatabaseWriter
  /// One read-only queue per reader: four for a file database, one for an in-memory one, whose readers hold read
  /// transactions that a commit has to wait for.
  let readers: [DatabaseQueue]
  private let turn = ReaderTurn()
  private let transactions = DispatchQueue(label: "wuwei.writer")

  init(writer: any DatabaseWriter, log: Logger = Logger(label: "wuhu.space")) throws {
    let inMemory = try writer.writeWithoutTransaction { db in
      try prepareConnection(db.sqliteConnection!)
      return String(cString: sqlite3_db_filename(db.sqliteConnection!, "main")).isEmpty
    }
    func makeReader(_ index: Int) throws -> DatabaseQueue {
      var configuration = Configuration()
      configuration.readonly = true
      configuration.busyMode = .timeout(5)
      configuration.prepareDatabase {
        try $0.execute(sql: PageCache.pragmas(cacheKiB: PageCache.readerKiB))
        try prepareConnection($0.sqliteConnection!)
        $0.traceSlowStatements(on: "wuwei.reader.\(index)", to: log)
      }
      return try DatabaseQueue(path: writer.path, configuration: configuration)
    }
    self.writer = writer
    readers = try (0 ..< (inMemory ? 1 : 4)).map(makeReader)
  }

  func write(_ body: (OpaquePointer, AnyObject?) throws -> Void) throws {
    try writer.write { try body(try open($0), $0) }
  }

  func begin() throws -> any SharedTransaction {
    let transaction = WriterTransaction()
    transactions.async { [self] in
      let result = Result {
        try writer.write { db in
          _ = try open(db)
          try transaction.serve(db)
        }
      }
      transaction.completed(result)
    }
    try transaction.waitUntilOpen()
    return transaction
  }

  func read(_ body: (OpaquePointer) throws -> Void) throws {
    let reader = readers[Int(turn.next.add(1, ordering: .relaxed).newValue % UInt64(readers.count))]
    try reader.read { try body(try open($0)) }
  }

  func close() throws {
    for reader in readers { try reader.close() }
  }

  /// GRDB runs what a cell or a job writes, so whoever watches a table (an observation, a push) hears of the rows a cell wrote.
  func execute(_ sql: String, _ arguments: [Value], on host: AnyObject?) throws -> Bool {
    do {
      try (host as! GRDB.Database).cachedStatement(sql: sql).execute(arguments: StatementArguments(arguments.map(\.databaseValue)))
    } catch let error as DatabaseError {
      throw SQLiteError(code: error.extendedResultCode.rawValue, message: error.message ?? error.description)
    }
    return true
  }

  /// A worker's last pokes can outlive the space that closed under it: they fail instead of trapping.
  private func open(_ db: GRDB.Database) throws -> OpaquePointer {
    guard let handle = db.sqliteConnection else { throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "the space database is closed") }
    return handle
  }
}

extension Value {
  fileprivate var databaseValue: DatabaseValue {
    switch self {
    case .null: .null
    case let .integer(value): value.databaseValue
    case let .real(value): value.databaseValue
    case let .text(value): value.databaseValue
    case let .blob(value): Data(value).databaseValue
    }
  }
}
