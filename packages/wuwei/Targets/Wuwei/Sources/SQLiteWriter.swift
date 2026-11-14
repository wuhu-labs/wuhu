import Dispatch
import GRDBSQLite
import Logging
import Synchronization

public final class SQLiteWriter: Sendable {
  public enum TransactionEvent: Sendable {
    case began, committed, rolledBack
  }

  fileprivate struct Hold {
    let label: String
    let waitingSince: UInt64
    let acquired: UInt64
    let blockedBy: (label: String, age: UInt64)?
    var begin: UInt64 = 0
    var bodyStarted: UInt64?
    var finishing: UInt64?
  }

  private struct Holder {
    let label: String
    let since: UInt64
  }

  private enum Outcome {
    case committed, rolledBack, accessed, closed, failed(any Error)
  }

  public let path: String
  private let connection: Mutex<Connection?>
  private let available = DispatchSemaphore(value: 1)
  private let holder = Mutex<Holder?>(nil)
  private let slowNanoseconds: UInt64 = 1_000_000_000
  private let log = Logger(label: "wuwei.writer")
  private let transaction: @Sendable (TransactionEvent) -> Void

  public init(
    path: String, flags: Int32, pragmas: [String] = [],
    transaction: @escaping @Sendable (TransactionEvent) -> Void = { _ in },
    prepare: (OpaquePointer) throws -> Void = { _ in },
  ) throws {
    self.path = path
    self.transaction = transaction
    let db = try Connection(path: path, flags: flags)
    do {
      db.setBusyHandler()
      for pragma in pragmas { try db.execute(pragma) }
      try prepare(db.handle)
      try prepareConnection(db.handle)
    } catch {
      try db.close()
      throw error
    }
    connection = Mutex(db)
  }

  public func access<T: Sendable>(label: String = "writer.access", _ body: (OpaquePointer) throws -> T) throws -> T {
    var hold = acquire(label)
    hold.bodyStarted = hold.acquired
    var outcome = Outcome.accessed
    defer { release(hold, outcome: outcome) }
    do { return try accessHeld { try body($0.handle) } }
    catch { outcome = .failed(error); throw error }
  }

  public func write(label: String = "writer.write", _ body: (OpaquePointer) throws -> Void) throws {
    var hold = acquire(label)
    var outcome = Outcome.committed
    defer { release(hold, outcome: outcome) }
    do {
      try accessHeld { db in
        try start(db, hold: &hold)
        do {
          try body(db.handle)
          hold.finishing = DispatchTime.now().uptimeNanoseconds
          try db.execute("COMMIT")
          transaction(.committed)
        } catch {
          if hold.finishing == nil { hold.finishing = DispatchTime.now().uptimeNanoseconds }
          rollback(db)
          throw error
        }
      }
    } catch { outcome = .failed(error); throw error }
  }

  public func begin(label: String = "writer.begin") throws -> any SharedTransaction {
    var hold = acquire(label)
    do { try accessHeld { try start($0, hold: &hold) } }
    catch { release(hold, outcome: .failed(error)); throw error }
    return WriterTransaction(writer: self, hold: hold)
  }

  public func close(label: String = "writer.close") throws {
    var hold = acquire(label)
    hold.bodyStarted = hold.acquired
    var outcome = Outcome.closed
    defer { release(hold, outcome: outcome) }
    do {
      try connection.withLock { db in
        if let db { try db.close() }
        db = nil
      }
    } catch { outcome = .failed(error); throw error }
  }

  private func acquire(_ label: String) -> Hold {
    let waitingSince = DispatchTime.now().uptimeNanoseconds
    let blockedBy = holder.withLock { $0.map { (label: $0.label, age: DispatchTime.now().uptimeNanoseconds - $0.since) } }
    available.wait()
    let acquired = DispatchTime.now().uptimeNanoseconds
    holder.withLock { $0 = Holder(label: label, since: acquired) }
    return Hold(label: label, waitingSince: waitingSince, acquired: acquired, blockedBy: blockedBy)
  }

  private func start(_ db: Connection, hold: inout Hold) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    defer { hold.begin = DispatchTime.now().uptimeNanoseconds - start }
    try db.execute("BEGIN IMMEDIATE")
    transaction(.began)
    hold.bodyStarted = DispatchTime.now().uptimeNanoseconds
  }

  private func release(_ hold: Hold, outcome: Outcome) {
    let ended = DispatchTime.now().uptimeNanoseconds
    holder.withLock { $0 = nil }
    available.signal()
    guard ended - hold.waitingSince > slowNanoseconds else { return }
    let wait = hold.acquired - hold.waitingSince
    let body = hold.bodyStarted.map { (hold.finishing ?? ended) - $0 } ?? 0
    let finish = hold.finishing.map { ended - $0 } ?? 0
    let result: String
    switch outcome {
    case .committed: result = "committed"
    case .rolledBack: result = "rolledBack"
    case .accessed: result = "accessed"
    case .closed: result = "closed"
    case let .failed(error): result = "failed(\(error))"
    }
    let blocker = wait > slowNanoseconds ? " blocked_by=\(hold.blockedBy?.label ?? "none") blocker_age_ms=\((hold.blockedBy?.age ?? 0) / 1_000_000)" : ""
    log.info("writer hold label=\(hold.label) wait_ms=\(wait / 1_000_000) begin_ms=\(hold.begin / 1_000_000) body_ms=\(body / 1_000_000) finish_ms=\(finish / 1_000_000) held_ms=\((ended - hold.acquired) / 1_000_000) outcome=\(result)\(blocker)")
  }

  private func accessHeld<T: Sendable>(_ body: (Connection) throws -> T) throws -> T {
    try connection.withLock {
      guard let db = $0 else { throw SQLiteError(code: SQLITE_MISUSE, message: "the writer is closed") }
      return try body(db)
    }
  }

  fileprivate func accessTransaction<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T {
    try accessHeld { try body($0.handle) }
  }

  fileprivate func finish(commit: Bool, hold: inout Hold) throws {
    hold.finishing = DispatchTime.now().uptimeNanoseconds
    var outcome: Outcome = commit ? .committed : .rolledBack
    defer { release(hold, outcome: outcome) }
    do {
      try accessHeld { db in
        if commit {
          do { try db.execute("COMMIT") }
          catch { rollback(db); throw error }
          transaction(.committed)
        } else {
          rollback(db)
        }
      }
    } catch { outcome = .failed(error); throw error }
  }

  private func rollback(_ db: Connection) {
    if db.inTransaction {
      do { try db.execute("ROLLBACK") }
      catch { preconditionFailure("could not roll back the writer: \(error)") }
    }
    transaction(.rolledBack)
  }

  deinit {
    do { try close() }
    catch { preconditionFailure("could not close the writer: \(error)") }
  }
}

private final class WriterTransaction: SharedTransaction {
  private var finished = false
  private let writer: SQLiteWriter
  private var hold: SQLiteWriter.Hold

  init(writer: SQLiteWriter, hold: SQLiteWriter.Hold) { self.writer = writer; self.hold = hold }

  func access<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T {
    precondition(!finished)
    return try writer.accessTransaction(body)
  }

  func commit() throws {
    precondition(!finished)
    finished = true
    try writer.finish(commit: true, hold: &hold)
  }

  func rollback() {
    precondition(!finished)
    finished = true
    do { try writer.finish(commit: false, hold: &hold) }
    catch { preconditionFailure("could not release the writer: \(error)") }
  }

  deinit { precondition(finished, "a held transaction must finish") }
}
