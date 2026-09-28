#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import GRDBSQLite
import struct SpaceContract.GroupID

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let multipleStatements =
  "Multiple statements found. To execute multiple statements, use Database.execute(sql:) or Database.allStatements(sql:) instead."

/// One raw connection reading the space file. The file is attached read-only
/// under a schema name only this connection knows, and a user statement names
/// public TEMP views, each reading a secretly named inner view of one table:
/// an unqualified name finds the TEMP view first, so the views are the only
/// names that reach the space tables.
///
/// The authorizer also asks that a column read of a space table come through
/// an inner view, so a leaked schema name alone gets past no filter. SQLite's
/// flattener leaves no accessor on a read of no column (a flattened
/// `count(*)`), so that read is admitted only for a table without a filter.
/// Every error message is scrubbed of both secrets, and SQLite has no way to
/// name a table but writing it, so a statement whose text holds either secret
/// is refused before it compiles.
final class ReadConnection {
  struct Secrets {
    let schema: String
    let views: String

    static func random() -> Secrets {
      Secrets(schema: randomHex(), views: randomHex())
    }

    private static func randomHex() -> String {
      var generator = SystemRandomNumberGenerator()
      return [generator.next(), generator.next()].map { (word: UInt64) in
        let hex = String(word, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
      }.joined()
    }
  }

  let handle: OpaquePointer
  private let gate: Gate
  private let schema: String
  private let viewPrefix: String
  private let secrets: Secrets
  private let screensText: Bool
  private var innerViews: [(inner: String, table: String)] = []
  private let catalog: ViewCatalog
  private let trace: (@Sendable (String) -> Void)?
  private var bound: Binding?
  private var forbiddenTables: Set<String> = []
  private var modules: Set<String> = []

  private struct Binding: Equatable {
    let schemaVersion: Int64
    let acting: GroupID
    let readable: Set<GroupID>
    let member: String?
  }

  init(
    path: String,
    catalog: ViewCatalog,
    trace: (@Sendable (String) -> Void)? = nil,
    secrets: Secrets = .random(),
    screensText: Bool = true,
  ) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
    let code = sqlite3_open_v2(":memory:", &handle, flags, nil)
    guard code == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) }
      if let handle { sqlite3_close_v2(handle) }
      throw DatabaseError(resultCode: ResultCode(rawValue: code), message: message)
    }
    self.handle = handle
    self.catalog = catalog
    self.trace = trace
    let schema = "s" + secrets.schema
    self.schema = schema
    self.viewPrefix = "__v" + secrets.views
    self.secrets = secrets
    self.screensText = screensText
    self.gate = Gate(schema: schema)
    sqlite3_extended_result_codes(handle, 1)
    sqlite3_busy_timeout(handle, 5000)
    let context = Unmanaged.passUnretained(gate).toOpaque()
    sqlite3_set_authorizer(handle, { context, action, first, second, database, accessor in
      Unmanaged<Gate>.fromOpaque(context!).takeUnretainedValue().verdict(
        action,
        first: first.map { String(cString: $0) },
        second: second.map { String(cString: $0) },
        database: database.map { String(cString: $0) },
        accessor: accessor.map { String(cString: $0) },
      )
    }, context)
    sqlite3_create_function_v2(handle, "viewer", 0, SQLITE_UTF8, context, { invocation, _, _ in
      let gate = Unmanaged<Gate>.fromOpaque(sqlite3_user_data(invocation)!).takeUnretainedValue()
      if let viewer = gate.viewer {
        sqlite3_result_text(invocation, viewer, -1, SQLITE_TRANSIENT)
      } else {
        sqlite3_result_null(invocation)
      }
    }, nil, nil, nil)
    try exec("PRAGMA trusted_schema = OFF")
    modules = try Set(strings("SELECT name FROM pragma_module_list")).subtracting(ViewCatalog.tableFunctions)
    try exec("ATTACH DATABASE \(Self.literal(Self.readOnlyURI(path))) AS \(quoted(schema))")
  }

  private static func readOnlyURI(_ path: String) -> String {
    var escaped: [UInt8] = []
    for byte in path.utf8 {
      switch byte {
      case UInt8(ascii: "%"), UInt8(ascii: "?"), UInt8(ascii: "#"):
        escaped += Array("%\(String(byte, radix: 16, uppercase: true))".utf8)
      default:
        escaped.append(byte)
      }
    }
    return "file:" + String(decoding: escaped, as: UTF8.self) + "?mode=ro"
  }

  private static func literal(_ text: String) -> String {
    "'" + text.replacing("'", with: "''") + "'"
  }

  deinit {
    sqlite3_close_v2(handle)
  }

  func run(
    _ sql: String,
    arguments: [DatabaseValue],
    byteLimit: Int?,
    scope: ReadScope,
  ) throws -> (ReadRows, ReadTables) {
    try transaction(sql, scope: scope) { statement in
      let rows = try self.rows(statement, sql: sql, arguments: arguments, byteLimit: byteLimit)
      return (rows, ReadTables(names: self.gate.read))
    }
  }

  func tables(_ sql: String, scope: ReadScope) throws -> ReadTables {
    try transaction(sql, scope: scope) { _ in ReadTables(names: self.gate.read) }
  }

  private func transaction<T>(_ sql: String, scope: ReadScope, _ body: (OpaquePointer) throws -> T) throws -> T {
    try SQLText.requireLeadingKeyword(sql)
    if screensText {
      let text = sql.lowercased()
      guard !text.contains(secrets.schema), !text.contains(secrets.views) else { throw ReadError.forbidden("main") }
    }
    gate.mode = .setup
    try exec("BEGIN")
    var rebound = false
    do {
      rebound = try bind(scope)
      gate.viewer = scope.viewer
      let result = try withStatement(sql, body)
      gate.mode = .setup
      try exec("COMMIT")
      return result
    } catch {
      gate.mode = .setup
      sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
      if rebound { bound = nil }
      throw error
    }
  }

  // The views match the snapshot the statement reads: they are rebuilt inside
  // its transaction whenever the schema or the scope moved since the last bind.
  private func bind(_ scope: ReadScope) throws -> Bool {
    let binding = try Binding(
      schemaVersion: integer("PRAGMA \(quoted(schema)).schema_version"),
      acting: scope.acting,
      readable: scope.readable,
      member: scope.member,
    )
    guard binding != bound else { return false }
    for view in try strings("SELECT name FROM temp.sqlite_master WHERE type = 'view'") {
      try exec("DROP VIEW temp.\(quoted(view))")
    }
    var columns: [String: [String]] = [:]
    for (table, column) in try pairs("""
    SELECT m.name, p.name FROM \(quoted(schema)).sqlite_master m
    JOIN pragma_table_info(m.name, \(Self.literal(schema))) p
    WHERE m.type = 'table' ORDER BY m.name, p.cid
    """) {
      columns[table, default: []].append(column)
    }
    let views = catalog.views(columns, scope)
    var filtered: Set<String> = []
    innerViews = []
    for (index, view) in views.enumerated() {
      let inner = "\(viewPrefix)_\(index)"
      let selected = view.columns.map { $0.map(quoted).joined(separator: ", ") } ?? "*"
      let condition = view.filter.map { " WHERE \($0)" } ?? ""
      let body = (view.select ?? "SELECT \(selected) FROM \(quoted(schema)).\(quoted(view.table))\(condition)")
        .replacing(ViewCatalog.schemaPlaceholder, with: quoted(schema))
      innerViews.append((inner, view.name))
      try exec("CREATE TEMP VIEW \(quoted(inner)) AS \(body)")
      try exec("CREATE TEMP VIEW \(quoted(view.name)) AS SELECT * FROM temp.\(quoted(inner))")
      if view.filter != nil || view.select != nil { filtered.insert(view.table) }
    }
    innerViews.sort { $0.inner.count > $1.inner.count }
    let names = Set(views.map(\.name))
    forbiddenTables = Set(columns.keys).subtracting(names)
    let named = try strings("SELECT name FROM \(quoted(schema)).sqlite_master WHERE type IN ('table', 'view')")
    gate.bind(
      visible: names, tables: Set(views.flatMap { [$0.table] + $0.joins }), inner: innerViews.map(\.inner), filtered: filtered,
      hidden: Set(named).subtracting(names).union(modules),
    )
    bound = binding
    return true
  }

  private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    gate.startStatement()
    let statement: OpaquePointer = try sql.withCString { start in
      var statement: OpaquePointer?
      var tail: UnsafePointer<CChar>?
      let code = sqlite3_prepare_v2(handle, start, -1, &statement, &tail)
      guard code == SQLITE_OK else {
        throw prepareFailure(failure(code, sql: sql), sql)
      }
      guard let statement else {
        throw prepareFailure(DatabaseError(resultCode: .SQLITE_ERROR, message: "empty statement", sql: sql), sql)
      }
      do {
        try requireSingleStatement(after: tail, sql: sql)
      } catch {
        sqlite3_finalize(statement)
        throw error
      }
      return statement
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_stmt_readonly(statement) != 0, sqlite3_stmt_isexplain(statement) == 0, !gate.wrote else {
      throw ReadError.notReadOnly
    }
    guard gate.denied.isEmpty else { throw ReadError.forbidden(gate.deniedList) }
    return try body(statement)
  }

  // As GRDB compiles one statement: whatever follows the first must be empty,
  // and anything else, compilable or not, is a misuse.
  private func requireSingleStatement(after tail: UnsafePointer<CChar>?, sql: String) throws {
    let saved = gate.flags
    defer { gate.flags = saved }
    var rest = tail
    while let current = rest, current.pointee != 0 {
      var extra: OpaquePointer?
      var next: UnsafePointer<CChar>?
      let code = sqlite3_prepare_v2(handle, current, -1, &extra, &next)
      if let extra { sqlite3_finalize(extra) }
      guard code == SQLITE_OK, extra == nil, next != current else {
        gate.flags = saved
        throw prepareFailure(DatabaseError(resultCode: .SQLITE_MISUSE, message: multipleStatements, sql: sql), sql)
      }
      rest = next
    }
  }

  // The gate's verdict outranks SQLite's own prepare error: a statement that
  // writes, or names a table outside the views, is refused as such even when
  // it is also broken.
  private func prepareFailure(_ error: DatabaseError, _ sql: String) -> any Error {
    if gate.wrote || error.message?.hasPrefix("cannot modify ") == true { return ReadError.notReadOnly }
    if let table = SQLText.identifier(in: sql, among: forbiddenTables) { return ReadError.forbidden(table) }
    if !gate.denied.isEmpty { return ReadError.forbidden(gate.deniedList) }
    if let name = error.message.flatMap(SQLText.unknownRelation) { return ReadError.unknownRelation(name) }
    return error
  }

  private func rows(_ statement: OpaquePointer, sql: String, arguments: [DatabaseValue], byteLimit: Int?) throws -> ReadRows {
    let count = sqlite3_column_count(statement)
    let columns = (0 ..< count).map { String(cString: sqlite3_column_name(statement, $0)) }
    let decltypes = (0 ..< count).map { sqlite3_column_decltype(statement, $0).map { String(cString: $0) } }
    let statementSQL = String(cString: sqlite3_sql(statement))
    guard Int(sqlite3_bind_parameter_count(statement)) == arguments.count else {
      throw DatabaseError(
        resultCode: .SQLITE_MISUSE,
        message: "wrong number of statement arguments: \(arguments.count)",
        sql: scrubbed(statementSQL),
      )
    }
    for (index, argument) in zip(Int32(1)..., arguments) {
      let code = argument.bind(to: statement, at: index)
      guard code == SQLITE_OK else {
        throw failure(code, sql: statementSQL)
      }
    }
    trace?(sql)
    var rows: [[DatabaseValue]] = []
    var bytes = 0
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else {
        throw failure(code, sql: statementSQL)
      }
      let row = (0 ..< count).map { DatabaseValue(sqliteStatement: statement, index: $0) }
      if let byteLimit {
        bytes += row.reduce(0) { $0 + Self.byteCount($1) }
        guard bytes <= byteLimit else { throw ReadError.tooLarge(byteLimit: byteLimit) }
      }
      rows.append(row)
    }
    return ReadRows(columns: columns, decltypes: decltypes, rows: rows)
  }

  private static func byteCount(_ value: DatabaseValue) -> Int {
    switch value.storage {
    case .null: 0
    case .int64, .double: 8
    case let .string(text): text.utf8.count
    case let .blob(data): data.count
    }
  }

  private func failure(_ code: Int32, sql: String) -> DatabaseError {
    DatabaseError(
      resultCode: ResultCode(rawValue: code),
      message: scrubbed(String(cString: sqlite3_errmsg(handle))),
      sql: scrubbed(sql),
    )
  }

  // What SQLite says about a view or the attached file names them; the caller
  // hears the table instead.
  func scrubbed(_ text: String) -> String {
    guard text.contains(schema) || text.contains(viewPrefix) else { return text }
    var text = text
    for (inner, table) in innerViews {
      text = text.replacing(quoted(inner), with: quoted(table)).replacing(inner, with: table)
    }
    return text
      .replacing(quoted(schema) + ".", with: "")
      .replacing(schema + ".", with: "")
      .replacing(schema, with: "main")
      .replacing(viewPrefix, with: "view")
  }

  private func exec(_ sql: String) throws {
    let code = sqlite3_exec(handle, sql, nil, nil, nil)
    guard code == SQLITE_OK else {
      throw failure(code, sql: sql)
    }
  }

  private func strings(_ sql: String) throws -> [String] {
    try fetch(sql) { String(cString: sqlite3_column_text($0, 0)) }
  }

  private func pairs(_ sql: String) throws -> [(String, String)] {
    try fetch(sql) { (String(cString: sqlite3_column_text($0, 0)), String(cString: sqlite3_column_text($0, 1))) }
  }

  private func integer(_ sql: String) throws -> Int64 {
    try fetch(sql) { sqlite3_column_int64($0, 0) }.first ?? 0
  }

  private func fetch<T>(_ sql: String, _ decode: (OpaquePointer) -> T) throws -> [T] {
    var statement: OpaquePointer?
    var code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else {
      throw failure(code, sql: sql)
    }
    defer { sqlite3_finalize(statement) }
    var values: [T] = []
    while true {
      code = sqlite3_step(statement)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW else {
        throw failure(code, sql: sql)
      }
      values.append(decode(statement))
    }
  }

  private func quoted(_ identifier: String) -> String {
    "\"" + identifier.replacing("\"", with: "\"\"") + "\""
  }
}

/// The authorizer's state. Setup mode is the connection's own work and may do
/// anything; user mode admits reads of the views and nothing else.
private final class Gate {
  enum Mode { case setup, user }

  struct Flags {
    var read: Set<String> = []
    var denied: Set<String> = []
    var wrote = false
  }

  let schema: String
  var mode = Mode.setup
  var viewer: String?
  var flags = Flags()
  private var visible: Set<String> = []
  private var tables: Set<String> = []
  private var inner: Set<String> = []
  private var filtered: Set<String> = []
  private var hidden: Set<String> = []

  init(schema: String) {
    self.schema = schema
  }

  func bind(visible: Set<String>, tables: Set<String>, inner: [String], filtered: Set<String>, hidden: Set<String>) {
    self.visible = Set(visible.map { $0.lowercased() })
    self.tables = Set(tables.map { $0.lowercased() })
    self.inner = Set(inner.map { $0.lowercased() })
    self.filtered = Set(filtered.map { $0.lowercased() })
    self.hidden = Set(hidden.map { $0.lowercased() })
  }

  var read: Set<String> { flags.read }
  var denied: Set<String> { flags.denied }
  var wrote: Bool { flags.wrote }
  var deniedList: String { flags.denied.sorted().joined(separator: ", ") }

  func startStatement() {
    flags = Flags()
    mode = .user
  }

  func verdict(_ action: Int32, first: String?, second: String?, database: String?, accessor: String?) -> Int32 {
    guard mode == .user else { return SQLITE_OK }
    switch action {
    case SQLITE_SELECT, SQLITE_RECURSIVE:
      return SQLITE_OK
    case SQLITE_READ:
      let table = first ?? ""
      let name = table.lowercased()
      if ViewCatalog.tableFunctions.contains(name) { return SQLITE_OK }
      switch database {
      case schema:
        // A column comes through an inner view, which carries the filter; a
        // read of no column carries no accessor, and a filter reads a column,
        // so only an unfiltered table is read that way.
        let throughAView = if let column = second, !column.isEmpty {
          accessor.map { inner.contains($0.lowercased()) } ?? false
        } else {
          !filtered.contains(name)
        }
        if tables.contains(name), throughAView {
          flags.read.insert(table)
          return SQLITE_OK
        }
      case "temp":
        if visible.contains(name) || inner.contains(name) { return SQLITE_OK }
      case nil:
        // A FROM item none of whose columns are read comes named as written,
        // with the qualifier as written: a CTE, a subquery, or whatever an
        // unqualified name resolves to, and a view's name resolves first.
        let resolvesPastTheViews = hidden.contains(name) || name.hasPrefix("sqlite_") || name.hasPrefix("pragma_")
        if visible.contains(name) || inner.contains(name) || !resolvesPastTheViews { return SQLITE_OK }
        flags.denied.insert(name)
        return SQLITE_IGNORE
      default:
        break
      }
      flags.denied.insert(table)
      return SQLITE_IGNORE
    case SQLITE_FUNCTION:
      let name = (second ?? "").lowercased()
      guard name != "load_extension", name != "fts3_tokenizer" else {
        flags.denied.insert(name)
        return SQLITE_DENY
      }
      return SQLITE_OK
    case SQLITE_PRAGMA:
      flags.denied.insert("pragma_" + (first ?? "").lowercased())
      return SQLITE_DENY
    default:
      flags.wrote = true
      return SQLITE_DENY
    }
  }
}
