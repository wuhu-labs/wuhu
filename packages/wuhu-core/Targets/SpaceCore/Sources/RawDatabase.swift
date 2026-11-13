#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDBSQLite

/// A connection of its own on a database file, beside whatever space holds that file open: it reads and writes rows as they are stored, under no cell and no owner guard. It waits five seconds for a busy database, as the space's own connections do, and enforces foreign keys.
final class RawDatabase {
  private let handle: OpaquePointer

  /// `path` may be a `file:` URI, as a memory space's is.
  init(path: String, readOnly: Bool = false) throws {
    var opened: OpaquePointer?
    let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_URI
    let code = sqlite3_open_v2(path, &opened, flags, nil)
    guard code == SQLITE_OK, let opened else {
      let failure = MigrationFailure(code: code, message: opened.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory")
      sqlite3_close_v2(opened)
      throw failure
    }
    sqlite3_busy_timeout(opened, 5000)
    do { try MigrationDB(handle: opened).execute(sql: "PRAGMA foreign_keys = ON") } catch {
      sqlite3_close_v2(opened)
      throw error
    }
    handle = opened
  }

  /// The connection is this object's: `body` returns values, never the connection.
  func access<T>(_ body: (MigrationDB) throws -> T) rethrows -> T {
    try body(MigrationDB(handle: handle))
  }

  /// Opens `path`, runs `body` and closes.
  static func open<T>(_ path: String, readOnly: Bool = false, _ body: (MigrationDB) throws -> T) throws -> T {
    try RawDatabase(path: path, readOnly: readOnly).access(body)
  }

  deinit { sqlite3_close_v2(handle) }
}

public func storedSpaceIdentity(at file: URL) throws -> SpaceIdentity? {
  try RawDatabase.open(file.path, readOnly: true) { db in
    try db.string("SELECT space_id FROM space_meta WHERE id = 1").map(SpaceIdentity.init(rawValue:))
  }
}
