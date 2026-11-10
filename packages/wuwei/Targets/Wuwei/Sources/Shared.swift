import GRDBSQLite
import Synchronization

/// The database the outer tables live in, and on the shared backend every addressable's tables too: one writer, any number of readers, whose connections the host program may own. Every connection runs ``prepareConnection(_:)`` once, when it opens.
public protocol SharedDatabase: Sendable {
  /// One write transaction on the writer: committed if `body` returns, rolled back if it throws. `host` is the host program's own object for this connection, which a cell takes as ``Database/host`` to write the host's tables through the host's code.
  func write(_ body: (_ handle: OpaquePointer, _ host: AnyObject?) throws -> Void) throws
  /// One read transaction, never on the writer: a read may run while a write is open.
  func read(_ body: (OpaquePointer) throws -> Void) throws
  /// One write statement of a cell or a job, inside the transaction `write` opened with `host`. A host program whose driver must see every write to its tables, to track changes, runs the statement itself and returns true; false leaves it to the runtime. A statement SQLite refuses throws ``SQLiteError``.
  func execute(_ sql: String, _ arguments: [Value], on host: AnyObject?) throws -> Bool
}

extension SharedDatabase {
  public func execute(_: String, _: [Value], on _: AnyObject?) throws -> Bool {
    false
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
  private let reader: Mutex<Connection>

  /// `path` may be a `file:` URI. `synchronous` is off only in tests: the file then never fsyncs, which still survives a simulated crash.
  public init(path: String, synchronous: Bool = true) throws {
    self.path = path
    let writer = try Connection(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI)
    try writer.execute("PRAGMA busy_timeout = 5000")
    try writer.execute("PRAGMA page_size = 8192")
    try writer.execute("PRAGMA journal_mode = WAL")
    try writer.execute(synchronous ? "PRAGMA synchronous = FULL" : "PRAGMA synchronous = OFF")
    for statement in Self.schema {
      try writer.execute(statement)
    }
    let reader = try Connection(path: path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    try reader.execute("PRAGMA busy_timeout = 5000")
    try Connection.prepare(writer.handle)
    try Connection.prepare(reader.handle)
    self.writer = Mutex(writer)
    self.reader = Mutex(reader)
  }

  /// The outer tables. A host program that keeps its own database creates them itself, `wuwei_pages` aside, which only the layered backend uses.
  static let schema = [
    """
    CREATE TABLE IF NOT EXISTS wuwei_addressable (
      id INTEGER PRIMARY KEY, address TEXT NOT NULL UNIQUE,
      holder TEXT NOT NULL, fence INTEGER NOT NULL, expires_at INTEGER NOT NULL, page_count INTEGER NOT NULL DEFAULT 0, wake_at INTEGER)
    """,
    "CREATE TABLE IF NOT EXISTS wuwei_pages (key INTEGER PRIMARY KEY, data BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS wuwei_mail (id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, payload BLOB NOT NULL)",
    "CREATE INDEX IF NOT EXISTS wuwei_mail_recipient ON wuwei_mail (recipient)",
    "CREATE TABLE IF NOT EXISTS wuwei_job (address TEXT PRIMARY KEY, params BLOB NOT NULL, phase TEXT NOT NULL DEFAULT 'new', wake_at INTEGER)",
    "CREATE TABLE IF NOT EXISTS wuwei_schema (kind TEXT PRIMARY KEY, applied INTEGER NOT NULL)",
  ]

  public func write(_ body: (OpaquePointer, AnyObject?) throws -> Void) throws {
    try writer.withLock { db in
      try db.execute("BEGIN IMMEDIATE")
      do {
        try body(db.handle, nil)
        try db.execute("COMMIT")
      } catch {
        try? db.execute("ROLLBACK")
        throw error
      }
    }
  }

  public func read(_ body: (OpaquePointer) throws -> Void) throws {
    try reader.withLock { db in
      try db.execute("BEGIN")
      defer { try? db.execute("COMMIT") }
      try body(db.handle)
    }
  }
}
