#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import Synchronization
import Wuwei

/// The space's wuwei runtime: one worker on the shared backend over the space's own database, hosting the kinds of every module of the space, on the date and clock injected where it is first asked for.
final class SpaceRuntime: Sendable {
  private let writer: any DatabaseWriter
  /// Held while a worker is made, which writes: a commit hook that pokes takes `running` alone.
  private let database = Mutex<WuweiDatabase?>(nil)
  private let running = Mutex<(worker: Worker, scheduler: DependencyScheduler)?>(nil)

  init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  func worker() -> Worker {
    database.withLock { database in
      if let running = running.withLock({ $0 }) { return running.worker }
      if database == nil {
        do { database = try WuweiDatabase(writer: writer) } catch { preconditionFailure("the space database took no reader: \(error)") }
      }
      let scheduler = DependencyScheduler()
      let worker = Worker(id: "space", storage: .shared(database!), scheduler: scheduler, registrations: [.cell(GroupCell.self), .cell(SpaceCell.self), .cell(PersonCell.self), .cell(ConversationCell.self)])
      running.withLock { $0 = (worker, scheduler) }
      return worker
    }
  }

  /// Has the session's cell look at its mail, after the write that posted it commits. Without a worker, or lost, a worker's scan finds the mail.
  func poke(_ session: SessionID) {
    running.withLock { $0?.worker }?.poke(Recipient<SessionMail>(kind: SessionMail.kind, key: session.rawValue))
  }

  /// The same for a person's cell.
  func poke(person: String) {
    running.withLock { $0?.worker }?.poke(PersonCell.ID(person).recipient)
  }

  func stop() async {
    guard let running = running.withLock({ running in
      defer { running = nil }
      return running
    }) else { return }
    await running.worker.drain()
    running.scheduler.stop()
  }

  func close() throws {
    try database.withLock { try $0?.reader.close() }
  }
}

extension Space {
  /// The space's one worker, which a module gives its kinds and clients before `start`. After `stopWorker` the next one is new, as after a restart of the process.
  public nonisolated var worker: Worker {
    runtime.worker()
  }

  /// Drains the worker and ends its timers.
  public nonisolated func stopWorker() async {
    await runtime.stop()
  }
}

private struct WuweiDatabase: SharedDatabase {
  let writer: any DatabaseWriter
  let reader: DatabaseQueue

  init(writer: any DatabaseWriter) throws {
    try writer.writeWithoutTransaction { try prepareConnection($0.sqliteConnection!) }
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { try prepareConnection($0.sqliteConnection!) }
    self.writer = writer
    reader = try DatabaseQueue(path: writer.path, configuration: configuration)
  }

  func write(_ body: (OpaquePointer, AnyObject?) throws -> Void) throws {
    try writer.write { try body(try open($0), $0) }
  }

  func read(_ body: (OpaquePointer) throws -> Void) throws {
    try reader.read { try body(try open($0)) }
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
