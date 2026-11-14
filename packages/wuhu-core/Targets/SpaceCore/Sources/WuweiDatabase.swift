#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDBSQLite
import Logging
import SpaceSQL
import Synchronization
import Wuwei

struct WuweiDatabase: SharedDatabase {
  enum JournalMode { case wal, `default` }

  static var openFlags: Int32 {
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | (sqlite3_libversion_number() >= 3_037_000 ? SQLITE_OPEN_EXRESCODE : 0)
  }

  let changes: ChangeSource
  let journalMode: JournalMode
  private let writer: SQLiteWriter
  private let readers: SQLiteReaders
  var path: String { writer.path }

  init(path: String, journalMode: JournalMode = .wal, changes: ChangeSource = ChangeSource(), log: Logger = Logger(label: "wuhu.space")) throws {
    self.changes = changes
    self.journalMode = journalMode
    let collector = WriterChanges(source: changes)
    var pragmas = ["PRAGMA busy_timeout = 5000", "PRAGMA foreign_keys = ON", "PRAGMA secure_delete = OFF"]
    if journalMode == .wal {
      pragmas += PageCache.pragmas(cacheKiB: PageCache.writerKiB).split(separator: ";").map(String.init)
    }
    writer = try SQLiteWriter(path: path, flags: Self.openFlags, pragmas: pragmas, transaction: { event in
      switch event {
      case .began, .rolledBack: collector.clear()
      case .committed: collector.committed()
      }
    }, prepare: { handle in
      sqlite3_extended_result_codes(handle, 1)
      let db = MigrationDB(handle: handle)
      if journalMode == .wal {
        guard try db.string("PRAGMA journal_mode = WAL") == "wal" else {
          throw SQLiteError(code: SQLITE_ERROR, message: "could not activate WAL mode")
        }
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        let wal = URL(fileURLWithPath: path + "-wal")
        if try !FileManager.default.fileExists(atPath: wal.path) || wal.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0 {
          try db.execute(sql: "SAVEPOINT grdb_issue_102; CREATE TABLE grdb_issue_102 (id INTEGER PRIMARY KEY); DROP TABLE grdb_issue_102; RELEASE grdb_issue_102")
        }
      }
      _ = try db.row("SELECT * FROM sqlite_master LIMIT 1")
      try collector.install(on: handle)
    })
    readers = SQLiteReaders(path: path, pragmas: PageCache.pragmas(cacheKiB: PageCache.readerKiB).split(separator: ";").map(String.init)) { connection, sql, milliseconds in
      SlowStatement.log(sql, milliseconds: milliseconds, on: connection, to: log)
    }
  }

  func accessWriter<T: Sendable>(label: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    try writer.access(label: label, body)
  }

  func write(label: String = "space.write", _ body: (OpaquePointer) throws -> Void) throws { try writer.write(label: label, body) }
  func begin(label: String = "space.begin") throws -> any SharedTransaction { try writer.begin(label: label) }
  func beginRead() throws -> any SharedReadTransaction { try readers.beginRead() }
  func closeReaders() { readers.close() }
  func closeWriter() throws { try writer.close(label: "space.close") }
}

private final class WriterChanges: Sendable {
  private let tables = Mutex<Set<String>>([])
  private let source: ChangeSource

  init(source: ChangeSource) { self.source = source }

  func install(on handle: OpaquePointer) throws {
    let context = Unmanaged.passRetained(self).toOpaque()
    let code = sqlite3_set_clientdata(handle, "wuhu.changes", context) { Unmanaged<WriterChanges>.fromOpaque($0!).release() }
    guard code == SQLITE_OK else { throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle))) }
    sqlite3_update_hook(handle, { context, _, database, table, _ in
      if String(cString: database!) == "main" {
        Unmanaged<WriterChanges>.fromOpaque(context!).takeUnretainedValue().record(table!)
      }
    }, context)
    let authorized = sqlite3_set_authorizer(handle, { context, action, table, _, database, _ in
      switch action {
      case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE:
        if String(cString: database!) == "main" {
          Unmanaged<WriterChanges>.fromOpaque(context!).takeUnretainedValue().record(table!)
        }
      default: break
      }
      return SQLITE_OK
    }, context)
    guard authorized == SQLITE_OK else { throw SQLiteError(code: authorized, message: String(cString: sqlite3_errmsg(handle))) }
  }

  private func record(_ table: UnsafePointer<CChar>) {
    tables.withLock { _ = $0.insert(String(cString: table)) }
  }

  func committed() {
    let touched = tables.withLock { tables in
      defer { tables.removeAll() }
      return tables
    }
    source.publish(touched)
  }

  func clear() { tables.withLock { $0.removeAll() } }
}
