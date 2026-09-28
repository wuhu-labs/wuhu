import Foundation
import GRDB
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS

enum Tables {
  static func encodeHeader(_ header: TableHeader) -> String {
    let columns = header.columns
      .map { "{\"name\":\(JSONValue.string($0.name).jsonString()),\"type\":\"\($0.type.rawValue)\"}" }
      .joined(separator: ",")
    return "{\"columns\":[\(columns)]}"
  }

  static func decodeHeader(_ json: String) throws -> TableHeader {
    guard let value = JSONValue.parse(json), let columns = value.object?["columns"]?.array else {
      throw SpaceError.notATable(json)
    }
    let parsed: [TableColumn] = try columns.map { element in
      guard let object = element.object,
            let name = object["name"]?.stringValue,
            let typeRaw = object["type"]?.stringValue,
            let type = TableColumn.ColumnType(rawValue: typeRaw)
      else { throw SpaceError.notATable(json) }
      return TableColumn(name: name, type: type)
    }
    return TableHeader(columns: parsed)
  }

  /// A user table's SQLite name: its group, a colon, its path.
  static func realName(_ group: GroupID, _ path: SpacePath) -> String {
    "\(group.rawValue):\(path.rawValue)"
  }

  static func quoted(_ group: GroupID, _ path: SpacePath) -> String {
    Cells.quote(realName(group, path))
  }

  /// The header of the live table at `path`. Schema versions outlive a move or a delete (history reads them), so
  /// liveness is the `tables` row, never the newest version.
  static func currentHeader(_ path: SpacePath, group: GroupID, in db: Database) throws -> TableHeader {
    guard try Substrate.tableExists(path, group: group, in: db) else { throw SpaceError.notATable(path.rawValue) }
    guard let json = try String.fetchOne(
      db,
      sql: "SELECT header_json FROM table_schema_versions WHERE grp = ? AND path = ? ORDER BY rev DESC LIMIT 1",
      arguments: [group.rawValue, path.rawValue],
    ) else { throw SpaceError.notATable(path.rawValue) }
    return try decodeHeader(json)
  }

  static func create(_ path: SpacePath, group: GroupID, header: TableHeader, rev: Int64, mtime: String, in db: Database) throws {
    if try Substrate.head(path, group: group, in: db) != nil || Substrate.tableExists(path, group: group, in: db) {
      throw SpaceError.alreadyExists(path.rawValue)
    }
    try Substrate.ensureAncestorDirectories(path, group: group, rev: rev, mtime: mtime, in: db)
    try db.execute(
      sql: "INSERT INTO tables (grp, path, created_rev) VALUES (?, ?, ?)", arguments: [group.rawValue, path.rawValue, rev],
    )
    try db.execute(
      sql: "INSERT INTO table_schema_versions (grp, path, rev, header_json) VALUES (?, ?, ?, ?)",
      arguments: [group.rawValue, path.rawValue, rev, encodeHeader(header)],
    )
    try db.execute(sql: createMaterializedSQL(path, group: group, header: header))
    try syncSequence(path, group: group, in: db)
    try Substrate.touchTableNode(path, group: group, rev: rev, mtime: mtime, in: db)
  }

  static func alter(_ path: SpacePath, group: GroupID, header: TableHeader, rev: Int64, mtime: String, in db: Database) throws {
    guard try Substrate.tableExists(path, group: group, in: db) else { throw SpaceError.notATable(path.rawValue) }
    let old = try currentHeader(path, group: group, in: db)
    let oldTypes = Dictionary(uniqueKeysWithValues: old.columns.map { ($0.name, $0.type) })
    for column in header.columns {
      if let oldType = oldTypes[column.name], oldType != column.type {
        throw SpaceError.columnTypeChanged("\(path.rawValue).\(column.name): \(oldType.rawValue) -> \(column.type.rawValue); drop and re-add the column instead")
      }
    }
    try db.execute(
      sql: "INSERT INTO table_schema_versions (grp, path, rev, header_json) VALUES (?, ?, ?, ?)",
      arguments: [group.rawValue, path.rawValue, rev, encodeHeader(header)],
    )
    let oldNames = Set(old.columns.map(\.name))
    let newNames = Set(header.columns.map(\.name))
    let table = quoted(group, path)
    for column in header.columns where !oldNames.contains(column.name) {
      try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(Cells.quote(column.name)) \(sqlType(column.type))")
    }
    for column in old.columns where !newNames.contains(column.name) {
      try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(Cells.quote(column.name))")
    }
    try Substrate.touchTableNode(path, group: group, rev: rev, mtime: mtime, in: db)
  }

  @discardableResult
  static func insertRow(
    _ path: SpacePath, group: GroupID, header: TableHeader, cells: [JSONValue], rev: Int64, in db: Database,
  ) throws -> Int64 {
    guard cells.count == header.columns.count else { throw SpaceError.columnCountMismatch(path.rawValue) }
    let table = quoted(group, path)
    if header.columns.isEmpty {
      try db.execute(sql: "INSERT INTO \(table) DEFAULT VALUES")
    } else {
      let columnList = header.columns.map { Cells.quote($0.name) }.joined(separator: ", ")
      let placeholders = header.columns.map { _ in "?" }.joined(separator: ", ")
      try db.execute(
        sql: "INSERT INTO \(table) (\(columnList)) VALUES (\(placeholders))",
        arguments: StatementArguments(try bindings(header: header, cells: cells)),
      )
    }
    let rowID = db.lastInsertedRowID
    try db.execute(
      sql: "INSERT INTO table_rows (grp, path, row_id, created_rev, deleted_rev, payload) VALUES (?, ?, ?, ?, NULL, ?)",
      arguments: [group.rawValue, path.rawValue, rowID, rev, payloadJSON(header: header, cells: cells)],
    )
    return rowID
  }

  /// The open row's positional payload, by column name.
  static func openPayload(_ path: SpacePath, group: GroupID, id: Int64, in db: Database) throws -> [String: JSONValue] {
    guard let payload = try String.fetchOne(
      db,
      sql: "SELECT payload FROM table_rows WHERE grp = ? AND path = ? AND row_id = ? AND deleted_rev IS NULL",
      arguments: [group.rawValue, path.rawValue, id],
    ) else { throw SpaceError.notFound("\(path.rawValue)#\(id)") }
    guard let object = JSONValue.parse(payload)?.object else { throw SpaceError.notFound("\(path.rawValue)#\(id)") }
    return Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.value) })
  }

  static func updateRow(
    _ path: SpacePath, group: GroupID, header: TableHeader, id: Int64, cells: [JSONValue], rev: Int64, in db: Database,
  ) throws {
    guard cells.count == header.columns.count else { throw SpaceError.columnCountMismatch(path.rawValue) }
    try closeOpenRow(path, group: group, id: id, rev: rev, in: db)
    try db.execute(
      sql: "INSERT INTO table_rows (grp, path, row_id, created_rev, deleted_rev, payload) VALUES (?, ?, ?, ?, NULL, ?)",
      arguments: [group.rawValue, path.rawValue, id, rev, payloadJSON(header: header, cells: cells)],
    )
    if !header.columns.isEmpty {
      let assignments = header.columns.map { "\(Cells.quote($0.name)) = ?" }.joined(separator: ", ")
      try db.execute(
        sql: "UPDATE \(quoted(group, path)) SET \(assignments) WHERE \"id\" = ?",
        arguments: StatementArguments(try bindings(header: header, cells: cells) + [id.databaseValue]),
      )
    }
  }

  static func deleteRow(_ path: SpacePath, group: GroupID, id: Int64, rev: Int64, in db: Database) throws {
    try closeOpenRow(path, group: group, id: id, rev: rev, in: db)
    try db.execute(sql: "DELETE FROM \(quoted(group, path)) WHERE \"id\" = ?", arguments: [id])
  }

  // A move copies the table's current state into the destination's journal at
  // `rev` and closes the source's, so the source path's history still replays
  // for a later checkout.
  static func reparent(
    from src: SpacePath, in srcGroup: GroupID, to dst: SpacePath, in dstGroup: GroupID, rev: Int64, in db: Database,
  ) throws {
    let header = try currentHeader(src, group: srcGroup, in: db)
    try db.execute(sql: "ALTER TABLE \(quoted(srcGroup, src)) RENAME TO \(quoted(dstGroup, dst))")
    try db.execute(sql: "DELETE FROM tables WHERE grp = ? AND path = ?", arguments: [srcGroup.rawValue, src.rawValue])
    try db.execute(
      sql: "INSERT INTO tables (grp, path, created_rev) VALUES (?, ?, ?)", arguments: [dstGroup.rawValue, dst.rawValue, rev],
    )
    try db.execute(
      sql: "INSERT INTO table_schema_versions (grp, path, rev, header_json) VALUES (?, ?, ?, ?)",
      arguments: [dstGroup.rawValue, dst.rawValue, rev, encodeHeader(header)],
    )
    try db.execute(
      sql: """
      INSERT INTO table_rows (grp, path, row_id, created_rev, deleted_rev, payload)
      SELECT ?, ?, row_id, ?, NULL, payload FROM table_rows WHERE grp = ? AND path = ? AND deleted_rev IS NULL
      """,
      arguments: [dstGroup.rawValue, dst.rawValue, rev, srcGroup.rawValue, src.rawValue],
    )
    try db.execute(
      sql: "UPDATE table_rows SET deleted_rev = ? WHERE grp = ? AND path = ? AND deleted_rev IS NULL",
      arguments: [rev, srcGroup.rawValue, src.rawValue],
    )
    try syncSequence(dst, group: dstGroup, in: db)
  }

  static func retire(_ path: SpacePath, group: GroupID, rev: Int64, in db: Database) throws {
    try db.execute(sql: "DROP TABLE IF EXISTS \(quoted(group, path))")
    try db.execute(sql: "DELETE FROM tables WHERE grp = ? AND path = ?", arguments: [group.rawValue, path.rawValue])
    try db.execute(
      sql: "UPDATE table_rows SET deleted_rev = ? WHERE grp = ? AND path = ? AND deleted_rev IS NULL",
      arguments: [rev, group.rawValue, path.rawValue],
    )
  }

  static func restore(_ path: SpacePath, group: GroupID, ceiling: Int64, rev: Int64, mtime: String, in db: Database) throws {
    let (header, rows) = try TableReplay.state(path, group: group, ceiling: ceiling, in: db)
    try db.execute(sql: "DROP TABLE IF EXISTS \(quoted(group, path))")
    try db.execute(
      sql: "UPDATE table_rows SET deleted_rev = ? WHERE grp = ? AND path = ? AND deleted_rev IS NULL",
      arguments: [rev, group.rawValue, path.rawValue],
    )
    try db.execute(
      sql: "INSERT OR IGNORE INTO tables (grp, path, created_rev) VALUES (?, ?, ?)",
      arguments: [group.rawValue, path.rawValue, rev],
    )
    try db.execute(
      sql: "INSERT INTO table_schema_versions (grp, path, rev, header_json) VALUES (?, ?, ?, ?)",
      arguments: [group.rawValue, path.rawValue, rev, encodeHeader(header)],
    )
    try db.execute(sql: createMaterializedSQL(path, group: group, header: header))
    for row in rows {
      let cells = header.columns.map { row.cells[$0.name] ?? .null }
      try insertMaterializedRow(path, group: group, header: header, id: row.id, cells: cells, in: db)
      try db.execute(
        sql: "INSERT INTO table_rows (grp, path, row_id, created_rev, deleted_rev, payload) VALUES (?, ?, ?, ?, NULL, ?)",
        arguments: [group.rawValue, path.rawValue, row.id, rev, payloadJSON(header: header, cells: cells)],
      )
    }
    try syncSequence(path, group: group, in: db)
    try Substrate.touchTableNode(path, group: group, rev: rev, mtime: mtime, op: .checkout, aux: String(ceiling), in: db)
  }

  static func liveRowIDs(_ path: SpacePath, group: GroupID, in db: Database) throws -> [Int64] {
    try Int64.fetchAll(
      db,
      sql: "SELECT \"id\" FROM \(quoted(group, path)) ORDER BY \"id\"",
    )
  }

  private static func closeOpenRow(_ path: SpacePath, group: GroupID, id: Int64, rev: Int64, in db: Database) throws {
    try db.execute(
      sql: "UPDATE table_rows SET deleted_rev = ? WHERE grp = ? AND path = ? AND row_id = ? AND deleted_rev IS NULL",
      arguments: [rev, group.rawValue, path.rawValue, id],
    )
    if db.changesCount == 0 { throw SpaceError.notFound("\(path.rawValue)#\(id)") }
  }

  static func insertMaterializedRow(
    _ path: SpacePath, group: GroupID, header: TableHeader, id: Int64, cells: [JSONValue], in db: Database,
  ) throws {
    let columnList = (["\"id\""] + header.columns.map { Cells.quote($0.name) }).joined(separator: ", ")
    let placeholders = (0 ... header.columns.count).map { _ in "?" }.joined(separator: ", ")
    try db.execute(
      sql: "INSERT INTO \(quoted(group, path)) (\(columnList)) VALUES (\(placeholders))",
      arguments: StatementArguments([id.databaseValue] + (try bindings(header: header, cells: cells))),
    )
  }

  // Row identity must be a lifecycle-unique key in table_rows, so the
  // materialized id sequence may never be reused after deletes, rebuilds, or
  // re-creation at the same path: AUTOINCREMENT plus an explicit sqlite_sequence
  // resync to the historical max row_id.
  static func syncSequence(_ path: SpacePath, group: GroupID, in db: Database) throws {
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(row_id), 0) FROM table_rows WHERE grp = ? AND path = ?",
      arguments: [group.rawValue, path.rawValue],
    ) ?? 0
    let name = realName(group, path)
    try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = ?", arguments: [name])
    if maxID > 0 {
      try db.execute(sql: "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", arguments: [name, maxID])
    }
  }

  static func createMaterializedSQL(_ path: SpacePath, group: GroupID, header: TableHeader) -> String {
    let columns = header.columns.map { "\(Cells.quote($0.name)) \(sqlType($0.type))" }
    let body = (["\"id\" INTEGER PRIMARY KEY AUTOINCREMENT"] + columns).joined(separator: ", ")
    return "CREATE TABLE \(quoted(group, path)) (\(body))"
  }

  // BOOLEAN and JSON_TEXT are recognized decltypes, not SQLite keywords: the
  // wire encoder rehydrates result cells by them (JSON_TEXT contains "TEXT" so
  // json columns keep TEXT affinity and never get numeric-coerced).
  private static func sqlType(_ type: TableColumn.ColumnType) -> String {
    switch type {
    case .text: "TEXT"
    case .integer: "INTEGER"
    case .real: "REAL"
    case .blob: "BLOB"
    case .boolean: "BOOLEAN"
    case .json: "JSON_TEXT"
    }
  }

  private static func bindings(header: TableHeader, cells: [JSONValue]) throws -> [DatabaseValue] {
    try zip(header.columns, cells).map { try Cells.binding($1, type: $0.type) }
  }

  static func payloadJSON(header: TableHeader, cells: [JSONValue]) -> String {
    let pairs = zip(header.columns, cells)
      .map { (name: $0.name, json: $1.jsonString(sortedKeys: true)) }
      .sorted { $0.name < $1.name }
    let body = pairs.map { "\(JSONValue.string($0.name).jsonString()):\($0.json)" }.joined(separator: ",")
    return "{\(body)}"
  }
}
