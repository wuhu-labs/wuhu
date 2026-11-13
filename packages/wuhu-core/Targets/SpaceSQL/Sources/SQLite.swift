import GRDBSQLite

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite value, with its storage class: what the sandbox binds as arguments and hands back as rows.
public enum SQLValue: Equatable, Sendable, CustomStringConvertible {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob([UInt8])

  public var description: String {
    switch self {
    case .null: "NULL"
    case let .integer(value): String(value)
    case let .real(value): String(value)
    case let .text(value): String(reflecting: value)
    case let .blob(value): "Data(\(value.description))"
    }
  }
}

extension SQLValue {
  init(sqliteStatement: OpaquePointer, index: Int32) {
    switch sqlite3_column_type(sqliteStatement, index) {
    case SQLITE_NULL: self = .null
    case SQLITE_INTEGER: self = .integer(sqlite3_column_int64(sqliteStatement, index))
    case SQLITE_FLOAT: self = .real(sqlite3_column_double(sqliteStatement, index))
    case SQLITE_TEXT: self = .text(String(cString: sqlite3_column_text(sqliteStatement, index)))
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(sqliteStatement, index))
      self = .blob(
        sqlite3_column_blob(sqliteStatement, index).map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? [],
      )
    case let type: preconditionFailure("a column of type \(type) carries no value")
    }
  }

  func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
    switch self {
    case .null: sqlite3_bind_null(statement, index)
    case let .integer(value): sqlite3_bind_int64(statement, index, value)
    case let .real(value): sqlite3_bind_double(statement, index, value)
    case let .text(value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    case let .blob(value) where value.isEmpty: sqlite3_bind_zeroblob(statement, index, 0)
    case let .blob(value): value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient) }
    }
  }

  var integer: Int64? {
    if case let .integer(value) = self { value } else { nil }
  }

  var text: String? {
    if case let .text(value) = self { value } else { nil }
  }
}

/// What SQLite refused a statement with: its extended result code, and the primary code the caller matches on.
public struct SQLiteFailure: Error, CustomStringConvertible {
  public let code: Int32
  public let message: String
  public let sql: String?

  public init(code: Int32, message: String, sql: String? = nil) {
    self.code = code
    self.message = message
    self.sql = sql
  }

  public var primary: Int32 {
    code & 0xFF
  }

  public var description: String {
    var description = "SQLite error \(primary): \(message)"
    if let sql { description += " - while executing `\(sql.trimmedSQL)`" }
    return description
  }
}

extension String {
  /// A compiled statement without the whitespace and semicolons around it, the way statements are reported.
  var trimmedSQL: String {
    var start = startIndex
    while start < endIndex, Self.isSQLSeparator(self[start]) { start = index(after: start) }
    var end = endIndex
    while end > start, Self.isSQLSeparator(self[index(before: end)]) { end = index(before: end) }
    return String(self[start ..< end])
  }

  private static func isSQLSeparator(_ character: Character) -> Bool {
    character == ";" || character.isWhitespace
  }
}
