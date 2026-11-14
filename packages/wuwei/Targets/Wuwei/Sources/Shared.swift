import GRDBSQLite

/// The database the outer tables live in, and on the shared backend every addressable's tables too: one writer, any number of readers, whose connections the host program may own. Every connection runs ``prepareConnection(_:)`` once, when it opens.
public protocol SharedDatabase: Sendable {
  /// One write transaction on the writer: committed if `body` returns, rolled back if it throws.
  func write(label: String, _ body: (OpaquePointer) throws -> Void) throws
  func begin(label: String) throws -> any SharedTransaction
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
  public func write(_ body: (OpaquePointer) throws -> Void) throws { try write(label: "writer.write", body) }
  public func begin() throws -> any SharedTransaction { try begin(label: "writer.begin") }

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
  private let writer: SQLiteWriter
  private let readers: SQLiteReaders

  /// `path` may be a `file:` URI. `synchronous` is off only in tests: the file then never fsyncs, which still survives a simulated crash.
  public init(path: String, synchronous: Bool = true) throws {
    self.path = path
    writer = try SQLiteWriter(
      path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
      pragmas: ["PRAGMA page_size = 8192", "PRAGMA journal_mode = WAL", synchronous ? "PRAGMA synchronous = FULL" : "PRAGMA synchronous = OFF"],
      prepare: { handle in
        let db = Connection(borrowing: handle)
        for statement in Self.schema { try db.execute(statement) }
        try db.transaction {
          for (table, column, type) in [("wuwei_job", "creator", "TEXT"), ("wuwei_mail", "lifecycle", "TEXT"), ("wuwei_addressable", "draining", "INTEGER NOT NULL DEFAULT 0")] {
            if try !db.rows("PRAGMA table_info(\(table))").contains(where: { $0["name"].text == column }) {
              try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
            }
          }
        }
      },
    )
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
    "CREATE INDEX IF NOT EXISTS wuwei_addressable_holder ON wuwei_addressable (holder, expires_at)",
    "CREATE TABLE IF NOT EXISTS wuwei_schema (kind TEXT PRIMARY KEY, applied INTEGER NOT NULL)",
  ]

  public func write(label: String = "writer.write", _ body: (OpaquePointer) throws -> Void) throws {
    try writer.write(label: label, body)
  }

  public func begin(label: String = "writer.begin") throws -> any SharedTransaction {
    try writer.begin(label: label)
  }

  public func beginRead() throws -> any SharedReadTransaction {
    try readers.beginRead()
  }
}
