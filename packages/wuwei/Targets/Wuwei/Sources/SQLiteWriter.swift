import Dispatch
import GRDBSQLite
import Synchronization

public final class SQLiteWriter: Sendable {
  public enum TransactionEvent: Sendable {
    case began, committed, rolledBack
  }

  public let path: String
  private let connection: Mutex<Connection?>
  private let available = DispatchSemaphore(value: 1)
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

  public func access<T: Sendable>(_ body: (OpaquePointer) throws -> T) throws -> T {
    available.wait()
    defer { available.signal() }
    return try accessHeld { try body($0.handle) }
  }

  public func write(_ body: (OpaquePointer) throws -> Void) throws {
    available.wait()
    defer { available.signal() }
    try accessHeld { db in
      try db.execute("BEGIN IMMEDIATE")
      transaction(.began)
      do {
        try body(db.handle)
        try db.execute("COMMIT")
        transaction(.committed)
      } catch {
        rollback(db)
        throw error
      }
    }
  }

  public func begin() throws -> any SharedTransaction {
    available.wait()
    do {
      try accessHeld { db in
        try db.execute("BEGIN IMMEDIATE")
        transaction(.began)
      }
    } catch {
      available.signal()
      throw error
    }
    return WriterTransaction(writer: self)
  }

  public func close() throws {
    available.wait()
    defer { available.signal() }
    try connection.withLock { db in
      if let db { try db.close() }
      db = nil
    }
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

  fileprivate func finish(commit: Bool) throws {
    defer { available.signal() }
    try accessHeld { db in
      if commit {
        do { try db.execute("COMMIT") }
        catch { rollback(db); throw error }
        transaction(.committed)
      } else {
        rollback(db)
      }
    }
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

  init(writer: SQLiteWriter) { self.writer = writer }

  func access<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T {
    precondition(!finished)
    return try writer.accessTransaction(body)
  }

  func commit() throws {
    precondition(!finished)
    finished = true
    try writer.finish(commit: true)
  }

  func rollback() {
    precondition(!finished)
    finished = true
    do { try writer.finish(commit: false) }
    catch { preconditionFailure("could not release the writer: \(error)") }
  }

  deinit { precondition(finished, "a held transaction must finish") }
}
