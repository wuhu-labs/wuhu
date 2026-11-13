import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDBSQLite
import Logging
import Wuwei

/// Runs the registered migrations on a raw SQLite connection, against the ledger GRDB's `DatabaseMigrator` left:
/// `grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)`, one `BEGIN IMMEDIATE` per migration with the identifier
/// inserted in it. Foreign keys stay as the connection was opened with them (GRDB's `.immediate` never touches the
/// pragma), so the writer's `foreignKeysEnabled` enforces them per statement throughout a migration.
struct MigrationRunner {
  let handle: OpaquePointer
  let log: Logger
  let date: DateGenerator
  let migrations: [(id: String, migrate: @Sendable (MigrationDB) throws -> Void)]

  func migrate() throws {
    let db = MigrationDB(handle: handle)
    try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
    let applied = Set(try db.strings("SELECT identifier FROM grdb_migrations"))
    let unknown = applied.subtracting(migrations.map { $0.id }).sorted()
    guard unknown.isEmpty else { throw SpaceError.unknownMigrations(unknown) }
    for (id, migrate) in migrations where !applied.contains(id) {
      log.notice("migration \(id): applying")
      let began = date.now
      try db.inImmediateTransaction {
        try migrate(db)
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [id])
      }
      log.notice("migration \(id): applied in \(Int(date.now.timeIntervalSince(began) * 1000)) ms")
    }
  }
}

/// A migration body's connection: one handle, statements run as they are written, nothing cached between them.
struct MigrationDB {
  let handle: OpaquePointer

  var lastInsertedRowID: Int64 {
    sqlite3_last_insert_rowid(handle)
  }

  func execute(sql: String) throws {
    _ = try run(sql, [])
  }

  func execute(sql: String, arguments: [any MigrationValue?]) throws {
    _ = try run(sql, arguments)
  }

  func rows(_ sql: String, arguments: [any MigrationValue?] = []) throws -> [MigrationRow] {
    try run(sql, arguments)
  }

  func row(_ sql: String, arguments: [any MigrationValue?] = []) throws -> MigrationRow? {
    try run(sql, arguments).first
  }

  /// The first column of every row.
  func strings(_ sql: String, arguments: [any MigrationValue?] = []) throws -> [String] {
    try run(sql, arguments).map { $0[0] }
  }

  /// The first column of the first row.
  func string(_ sql: String, arguments: [any MigrationValue?] = []) throws -> String? {
    guard let row = try row(sql, arguments: arguments) else { return nil }
    return row[0]
  }

  func int(_ sql: String, arguments: [any MigrationValue?] = []) throws -> Int? {
    guard let row = try row(sql, arguments: arguments) else { return nil }
    return row[0]
  }

  func bool(_ sql: String, arguments: [any MigrationValue?] = []) throws -> Bool? {
    guard let row = try row(sql, arguments: arguments) else { return nil }
    return row[0]
  }

  func tableExists(_ name: String) throws -> Bool {
    try !rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE", arguments: [name]).isEmpty
  }

  func columns(in table: String) throws -> [String] {
    try strings("SELECT name FROM pragma_table_xinfo(?) WHERE hidden != 1", arguments: [table])
  }

  func inImmediateTransaction(_ body: () throws -> Void) throws {
    try execute(sql: "BEGIN IMMEDIATE")
    do {
      try body()
      try execute(sql: "COMMIT")
    } catch {
      // A failed COMMIT (busy, a deferred constraint) leaves the transaction open; SQLite rolls it back on its own only for some failures (disk full, I/O error, busy), and the first error is the one to keep.
      if sqlite3_get_autocommit(handle) == 0 { try? execute(sql: "ROLLBACK") }
      throw error
    }
  }

  /// Every statement in `sql`, in order, with `arguments` consumed across them as GRDB's cursor does.
  private func run(_ sql: String, _ arguments: [any MigrationValue?]) throws -> [MigrationRow] {
    var remaining = arguments[...]
    var rows: [MigrationRow] = []
    try sql.withCString { text in
      var cursor: UnsafePointer<CChar>? = text
      while let start = cursor, start.pointee != 0 {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, start, -1, &statement, &cursor)
        guard prepared == SQLITE_OK else { throw failure(prepared) }
        guard let statement else { break }
        do {
          defer { sqlite3_finalize(statement) }
          let count = Int(sqlite3_bind_parameter_count(statement))
          precondition(count <= remaining.count, "\(sql): \(count) parameters, \(remaining.count) arguments")
          for (offset, argument) in remaining.prefix(count).enumerated() {
            try bind(argument, to: statement, at: Int32(offset + 1))
          }
          remaining = remaining.dropFirst(count)
          let columns = (0 ..< sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
          stepping: while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break stepping }
            guard step == SQLITE_ROW else { throw failure(step) }
            rows.append(MigrationRow(columns: columns, values: columns.indices.map { column(statement, Int32($0)) }))
          }
        }
      }
    }
    precondition(remaining.isEmpty, "\(sql): unused arguments")
    return rows
  }

  private func bind(_ argument: (any MigrationValue)?, to statement: OpaquePointer?, at index: Int32) throws {
    let bound: Int32
    switch argument?.value ?? .null {
    case .null: bound = sqlite3_bind_null(statement, index)
    case let .integer(integer): bound = sqlite3_bind_int64(statement, index, integer)
    case let .real(real): bound = sqlite3_bind_double(statement, index, real)
    case let .text(text): bound = sqlite3_bind_text(statement, index, text, -1, transient)
    case let .blob(bytes) where bytes.isEmpty: bound = sqlite3_bind_zeroblob(statement, index, 0)
    case let .blob(bytes):
      bound = bytes.withUnsafeBufferPointer { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
    }
    guard bound == SQLITE_OK else { throw failure(bound) }
  }

  private func column(_ statement: OpaquePointer?, _ index: Int32) -> Value {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
    case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
    case SQLITE_BLOB: .blob(Array(UnsafeRawBufferPointer(start: sqlite3_column_blob(statement, index), count: Int(sqlite3_column_bytes(statement, index)))))
    default: .null
    }
  }

  private func failure(_ code: Int32) -> MigrationFailure {
    MigrationFailure(code: code, message: String(cString: sqlite3_errmsg(handle)))
  }
}

/// A statement SQLite refused, or a row it returned that a body asked for as another type.
struct MigrationFailure: Error, CustomStringConvertible {
  let code: Int32
  let message: String

  var description: String {
    "\(message) (SQLite \(code))"
  }
}

struct MigrationRow {
  let columns: [String]
  let values: [Value]

  subscript(_ column: String) -> Value {
    values[index(of: column)]
  }

  subscript<Converted: MigrationValue>(_ column: String) -> Converted {
    let value = values[index(of: column)]
    guard let converted = Converted(value) else { preconditionFailure("\(column) is not a \(Converted.self): \(value)") }
    return converted
  }

  subscript(_ index: Int) -> Value {
    values[index]
  }

  subscript<Converted: MigrationValue>(_ index: Int) -> Converted {
    guard let converted = Converted(values[index]) else { preconditionFailure("column \(index) is not a \(Converted.self): \(values[index])") }
    return converted
  }

  private func index(of column: String) -> Int {
    guard let index = columns.firstIndex(of: column) else { preconditionFailure("no column \(column) in \(columns)") }
    return index
  }
}

protocol MigrationValue {
  var value: Value { get }
  init?(_ value: Value)
}

extension Value: MigrationValue {
  var value: Value { self }

  init?(_ value: Value) {
    self = value
  }
}

extension String: MigrationValue {
  var value: Wuwei.Value { .text(self) }

  init?(_ value: Wuwei.Value) {
    guard case let .text(text) = value else { return nil }
    self = text
  }
}

extension Data: MigrationValue {
  var value: Wuwei.Value { .blob(Array(self)) }

  init?(_ value: Wuwei.Value) {
    guard case let .blob(bytes) = value else { return nil }
    self = Data(bytes)
  }
}

extension Int: MigrationValue {
  var value: Wuwei.Value { .integer(Int64(self)) }

  init?(_ value: Wuwei.Value) {
    guard case let .integer(integer) = value else { return nil }
    self = Int(integer)
  }
}

extension Int64: MigrationValue {
  var value: Wuwei.Value { .integer(self) }

  init?(_ value: Wuwei.Value) {
    guard case let .integer(integer) = value else { return nil }
    self = integer
  }
}

extension Bool: MigrationValue {
  var value: Wuwei.Value { .integer(self ? 1 : 0) }

  init?(_ value: Wuwei.Value) {
    guard case let .integer(integer) = value else { return nil }
    self = integer != 0
  }
}

// `Wuwei.Value` spelled in full: inside an extension of `Optional`, the bare name is SwiftUI's `Gesture.Value`.
extension Optional: MigrationValue where Wrapped: MigrationValue {
  var value: Wuwei.Value { self?.value ?? .null }

  init?(_ value: Wuwei.Value) {
    if case .null = value {
      self = .none
    } else {
      guard let wrapped = Wrapped(value) else { return nil }
      self = wrapped
    }
  }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
