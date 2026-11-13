import Dispatch
import GRDBSQLite
import Synchronization

/// The database the outer tables live in, and on the shared backend every addressable's tables too: one writer, any number of readers, whose connections the host program may own. Every connection runs ``prepareConnection(_:)`` once, when it opens.
public protocol SharedDatabase: Sendable {
  /// One write transaction on the writer: committed if `body` returns, rolled back if it throws.
  func write(_ body: (OpaquePointer) throws -> Void) throws
  func begin() throws -> any SharedTransaction
  /// One read transaction, never on the writer: a read may run while a write is open.
  func read(_ body: (OpaquePointer) throws -> Void) throws
  func beginRead() throws -> any SharedReadTransaction
}

/// A writer held until commit or rollback. Access is synchronous, on the host's writer; only the command and its Sendable result cross that boundary, never a borrowed connection. Either terminal operation releases the writer, including a failed commit; access throws only for that command and leaves the transaction open.
public protocol SharedTransaction {
  func access<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T
  func commit() throws
  func rollback()
}

/// A reader held until the last reference is released. Its deferred transaction shares one snapshot across synchronous accesses; no borrowed handle may escape an access.
public protocol SharedReadTransaction: AnyObject {
  func access<T: Sendable>(_ body: (OpaquePointer) throws -> T) rethrows -> T
}

extension SharedDatabase {
  public func read(_ body: (OpaquePointer) throws -> Void) throws {
    try beginRead().access(body)
  }
}

/// Defines `cell()` on a connection: the key of the addressable whose statement runs on it, `NULL` outside one.
public func prepareConnection(_ handle: OpaquePointer) throws {
  try Connection.prepare(handle)
}

/// Where addressables keep their tables. Layered: a SQLite database each, whose pages are rows of the file, written in epochs. Shared: their tables live in the shared database itself, and every step commits on its own.
public enum Storage: Sendable {
  case layered(FileDatabase)
  case shared(any SharedDatabase)
}

/// A shared database in a file of the runtime's own, in WAL mode, with the outer tables.
public final class FileDatabase: SharedDatabase {
  let path: String
  private let writer: Mutex<Connection>
  private let available = DispatchSemaphore(value: 1)
  private let readers: SQLiteReaders

  /// `path` may be a `file:` URI. `synchronous` is off only in tests: the file then never fsyncs, which still survives a simulated crash.
  public init(path: String, synchronous: Bool = true) throws {
    self.path = path
    let writer = try Connection(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI)
    writer.setBusyHandler()
    try writer.execute("PRAGMA page_size = 8192")
    try writer.execute("PRAGMA journal_mode = WAL")
    try writer.execute(synchronous ? "PRAGMA synchronous = FULL" : "PRAGMA synchronous = OFF")
    for statement in Self.schema {
      try writer.execute(statement)
    }
    try writer.transaction {
      for (table, column, type) in [("wuwei_job", "creator", "TEXT"), ("wuwei_mail", "lifecycle", "TEXT"), ("wuwei_addressable", "draining", "INTEGER NOT NULL DEFAULT 0")] {
        if try !writer.rows("PRAGMA table_info(\(table))").contains(where: { $0["name"].text == column }) {
          try writer.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
      }
    }
    try Connection.prepare(writer.handle)
    self.writer = Mutex(writer)
    readers = SQLiteReaders(path: path)
  }

  /// The outer tables. A host program that keeps its own database creates them itself, `wuwei_pages` aside, which only the layered backend uses.
  static let schema = [
    """
    CREATE TABLE IF NOT EXISTS wuwei_addressable (
      id INTEGER PRIMARY KEY, address TEXT NOT NULL UNIQUE,
      holder TEXT NOT NULL, fence INTEGER NOT NULL, expires_at INTEGER NOT NULL, draining INTEGER NOT NULL DEFAULT 0, page_count INTEGER NOT NULL DEFAULT 0, wake_at INTEGER)
    """,
    "CREATE TABLE IF NOT EXISTS wuwei_pages (key INTEGER PRIMARY KEY, data BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS wuwei_mail (id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, payload BLOB NOT NULL)",
    "CREATE INDEX IF NOT EXISTS wuwei_mail_recipient ON wuwei_mail (recipient)",
    "CREATE TABLE IF NOT EXISTS wuwei_job (address TEXT PRIMARY KEY, params BLOB NOT NULL, phase TEXT NOT NULL DEFAULT 'new', wake_at INTEGER)",
    "CREATE INDEX IF NOT EXISTS wuwei_job_pending ON wuwei_job (address, wake_at) WHERE phase != 'done'",
    "CREATE INDEX IF NOT EXISTS wuwei_addressable_wake ON wuwei_addressable (wake_at) WHERE wake_at IS NOT NULL",
    "CREATE TABLE IF NOT EXISTS wuwei_schema (kind TEXT PRIMARY KEY, applied INTEGER NOT NULL)",
  ]

  public func write(_ body: (OpaquePointer) throws -> Void) throws {
    available.wait()
    defer { available.signal() }
    try writer.withLock { db in
      try db.execute("BEGIN IMMEDIATE")
      do {
        try body(db.handle)
        try db.execute("COMMIT")
      } catch {
        try? db.execute("ROLLBACK")
        throw error
      }
    }
  }

  public func begin() throws -> any SharedTransaction {
    available.wait()
    do { try accessWriter { try Connection(borrowing: $0).execute("BEGIN IMMEDIATE") } }
    catch { available.signal(); throw error }
    return FileTransaction(database: self)
  }

  fileprivate func accessWriter<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) rethrows -> T {
    try writer.withLock { try body($0.handle) }
  }

  fileprivate func finishWriter() {
    available.signal()
  }

  public func beginRead() throws -> any SharedReadTransaction {
    try readers.beginRead()
  }
}

private final class FileTransaction: SharedTransaction {
  private var finished = false
  private let database: FileDatabase

  init(database: FileDatabase) { self.database = database }

  func access<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T {
    precondition(!finished)
    return try database.accessWriter { try body($0) }
  }

  func commit() throws {
    precondition(!finished)
    finished = true
    defer { database.finishWriter() }
    try database.accessWriter { handle in
      let db = Connection(borrowing: handle)
      do { try db.execute("COMMIT") }
      catch { try? db.execute("ROLLBACK"); throw error }
    }
  }

  func rollback() {
    precondition(!finished)
    finished = true
    try? database.accessWriter { try Connection(borrowing: $0).execute("ROLLBACK") }
    database.finishWriter()
  }

  deinit { precondition(finished, "a held transaction must finish") }
}
