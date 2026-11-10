import GRDBSQLite

public enum Value: Sendable, Hashable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob([UInt8])

  public var integer: Int64? {
    if case let .integer(value) = self { value } else { nil }
  }

  public var text: String? {
    if case let .text(value) = self { value } else { nil }
  }

  public var blob: [UInt8]? {
    if case let .blob(value) = self { value } else { nil }
  }
}

extension Value: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral {
  public init(integerLiteral value: Int64) {
    self = .integer(value)
  }

  public init(stringLiteral value: String) {
    self = .text(value)
  }

  public init(nilLiteral _: ()) {
    self = .null
  }
}

public struct Row: Sendable {
  let columns: [String]
  let values: [Value]

  public subscript(_ index: Int) -> Value {
    values[index]
  }

  public subscript(_ column: String) -> Value {
    guard let index = columns.firstIndex(of: column) else { preconditionFailure("no column \(column) in \(columns)") }
    return values[index]
  }
}

struct SQLiteError: Error, CustomStringConvertible {
  let code: Int32
  let message: String

  var primary: Int32 {
    code & 0xFF
  }

  var description: String {
    "sqlite \(code): \(message)"
  }
}

/// A cell's database, or any read handle's. A read runs only read-only statements and a write is `mutating`, so a nonmutating method cannot write; on a read handle a write traps. A cell call is one whole step, so only what depends on the data throws: a constraint violation. Anything else, a bad statement or a failing disk, traps.
public struct Database {
  let access: Access

  public func rows(_ sql: String, _ arguments: Value...) -> [Row] {
    access.read(sql, arguments)
  }

  public func rows(_ sql: String, _ arguments: [Value]) -> [Row] {
    access.read(sql, arguments)
  }

  /// The first column of the first row.
  public func one(_ sql: String, _ arguments: Value...) -> Value? {
    access.read(sql, arguments).first?[0]
  }

  public mutating func execute(_ sql: String, _ arguments: Value...) throws(ConstraintViolation) {
    try execute(sql, arguments)
  }

  /// On the shared backend, the host program's object for the connection this call writes on, as its ``SharedDatabase`` passed it; `nil` on the layered backend. What the call writes through it commits and rolls back with the call.
  public var host: AnyObject? {
    access.incarnation.hostConnection
  }

  public mutating func execute(_ sql: String, _ arguments: [Value]) throws(ConstraintViolation) {
    switch access.write(sql, arguments) {
    case .success: return
    case let .failure(.constraint(violation)): throw violation
    case let .failure(.storage(error)): preconditionFailure("\(sql): \(error)")
    }
  }
}

/// A job's database. Reads behave as a cell's; a write that the disk fails ends the incarnation and throws ``Evicted``, so the job's `start` unwinds and the next delivery hydrates a fresh one from durable state. On a read handle a write traps.
public struct JobDatabase {
  let access: Access

  public func rows(_ sql: String, _ arguments: Value...) -> [Row] {
    access.read(sql, arguments)
  }

  public func rows(_ sql: String, _ arguments: [Value]) -> [Row] {
    access.read(sql, arguments)
  }

  public func one(_ sql: String, _ arguments: Value...) -> Value? {
    access.read(sql, arguments).first?[0]
  }

  public mutating func execute(_ sql: String, _ arguments: Value...) throws {
    try execute(sql, arguments)
  }

  public mutating func execute(_ sql: String, _ arguments: [Value]) throws {
    switch access.write(sql, arguments) {
    case .success: return
    case let .failure(.constraint(violation)): throw violation
    case let .failure(.storage(error)):
      access.incarnation.fail(error)
      throw Evicted(address: access.incarnation.address)
    }
  }
}

/// Where an addressable's statements run.
enum Access {
  /// The live incarnation, the only writer.
  case live(Incarnation)
  /// A layered read handle's own copy of the database.
  case copy(Connection)
  /// A shared read handle: each statement is a fresh read, on the step open in `within` if there is one.
  case shared(OuterStore, owner: String, within: Incarnation?)

  var incarnation: Incarnation {
    guard case let .live(incarnation) = self else { preconditionFailure("a read handle cannot write") }
    return incarnation
  }

  func read(_ sql: String, _ arguments: [Value]) -> [Row] {
    switch self {
    case let .live(incarnation): return incarnation.read(sql, arguments)
    case let .copy(connection): return connection.read(sql, arguments)
    case let .shared(store, owner, within):
      if let rows = within?.readOpen(as: owner, sql, arguments) { return rows }
      do { return try store.read(owner: owner) { $0.read(sql, arguments) } } catch { preconditionFailure("\(sql): \(error)") }
    }
  }

  func write(_ sql: String, _ arguments: [Value]) -> Result<Void, WriteFailure> {
    incarnation.write(sql, arguments)
  }
}

public struct ConstraintViolation: Error {
  public let message: String
}

enum WriteFailure: Error {
  case constraint(ConstraintViolation)
  case storage(any Error)
}

extension Connection {
  func read(_ sql: String, _ arguments: [Value]) -> [Row] {
    do { return try rows(sql, arguments, readOnly: true) } catch { preconditionFailure("\(sql): \(error)") }
  }

  /// A statement that cannot run is a bug and traps here; what remains is the data's fault or the disk's.
  func write(_ sql: String, _ arguments: [Value]) -> Result<Void, WriteFailure> {
    do {
      _ = try rows(sql, arguments)
      return .success(())
    } catch let error as SQLiteError where error.primary == SQLITE_CONSTRAINT {
      return .failure(.constraint(ConstraintViolation(message: error.message)))
    } catch let error as SQLiteError where [SQLITE_IOERR, SQLITE_FULL, SQLITE_NOMEM, SQLITE_CORRUPT, SQLITE_NOTADB].contains(error.primary) {
      return .failure(.storage(error))
    } catch {
      preconditionFailure("\(sql): \(error)")
    }
  }
}

/// One SQLite connection. Not `Sendable`: it belongs to whoever opened it, or, borrowed, to the call it was lent to.
final class Connection {
  let handle: OpaquePointer
  private let owned: Bool
  /// The host program's object for a borrowed writer, on the shared backend.
  var host: AnyObject?

  init(path: String, flags: Int32, vfs: String? = nil) throws {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(path, &handle, flags, vfs)
    guard code == SQLITE_OK, let handle else {
      defer { sqlite3_close_v2(handle) }
      throw SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open \(path)")
    }
    self.handle = handle
    owned = true
  }

  init(borrowing handle: OpaquePointer) {
    self.handle = handle
    owned = false
  }

  deinit {
    if owned { sqlite3_close_v2(handle) }
  }

  static func prepare(_ handle: OpaquePointer) throws {
    let owner = Unmanaged.passRetained(Owner()).toOpaque()
    sqlite3_set_clientdata(handle, ownerSlot, owner) { Unmanaged<Owner>.fromOpaque($0!).release() }
    let code = sqlite3_create_function_v2(handle, "cell", 0, SQLITE_UTF8, owner, { context, _, _ in
      if let key = Unmanaged<Owner>.fromOpaque(sqlite3_user_data(context)).takeUnretainedValue().key {
        sqlite3_result_text(context, key, -1, transient)
      } else {
        sqlite3_result_null(context)
      }
    }, nil, nil, nil)
    guard code == SQLITE_OK else { throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle))) }
  }

  /// What `cell()` returns on this connection.
  var owner: String? {
    get { slot.key }
    set { slot.key = newValue }
  }

  private var slot: Owner {
    guard let slot = sqlite3_get_clientdata(handle, ownerSlot) else { preconditionFailure("cell() is not defined on this connection: prepareConnection(_:) never ran") }
    return Unmanaged<Owner>.fromOpaque(slot).takeUnretainedValue()
  }

  func execute(_ sql: String, _ arguments: Value...) throws {
    _ = try rows(sql, arguments)
  }

  func rows(_ sql: String, _ arguments: Value...) throws -> [Row] {
    try rows(sql, arguments)
  }

  /// Runs `body` inside a savepoint: a throw rolls back exactly what `body` wrote.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("SAVEPOINT body")
    do {
      let result = try body()
      try execute("RELEASE body")
      return result
    } catch {
      try execute("ROLLBACK TO body")
      try execute("RELEASE body")
      throw error
    }
  }

  func rows(_ sql: String, _ arguments: [Value], readOnly: Bool = false) throws -> [Row] {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let rest = try sql.withCString { text in
      var tail: UnsafePointer<CChar>?
      try check(sqlite3_prepare_v2(handle, text, -1, &statement, &tail))
      return tail.map { String(cString: $0) } ?? ""
    }
    precondition(rest.allSatisfy(\.isWhitespace), "one statement at a time: \(sql)")
    precondition(!readOnly || sqlite3_stmt_readonly(statement) != 0, "not a read: \(sql)")
    for (index, argument) in arguments.enumerated() {
      try check(bind(argument, to: statement, at: Int32(index + 1)))
    }
    let columns = (0 ..< sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
    var rows: [Row] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return rows }
      guard code == SQLITE_ROW else { throw error(code) }
      rows.append(Row(columns: columns, values: columns.indices.map { column(statement, Int32($0)) }))
    }
  }

  private func bind(_ value: Value, to statement: OpaquePointer?, at index: Int32) -> Int32 {
    switch value {
    case .null: sqlite3_bind_null(statement, index)
    case let .integer(value): sqlite3_bind_int64(statement, index, value)
    case let .real(value): sqlite3_bind_double(statement, index, value)
    case let .text(value): sqlite3_bind_text(statement, index, value, -1, transient)
    case let .blob(value) where value.isEmpty: sqlite3_bind_zeroblob(statement, index, 0)
    case let .blob(value): value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
    }
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

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK else { throw error(code) }
  }

  private func error(_ code: Int32) -> SQLiteError {
    SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
  }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let ownerSlot = "wuwei.owner"

private final class Owner {
  var key: String?
}
