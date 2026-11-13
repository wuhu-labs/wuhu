#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

extension FilesCell {
  func tableExists(_ path: SpacePath) -> Bool {
    let key = id.key
    return !db.rows(TableNodeRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }).isEmpty
  }

  func currentHeader(_ path: SpacePath) throws -> TableHeader {
    guard tableExists(path) else { throw SpaceError.notATable(path.rawValue) }
    let key = id.key
    guard let schema = db.rows(TableSchemaVersionRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.order { $0.rev.desc() }.limit(1)).first else {
      throw SpaceError.notATable(path.rawValue)
    }
    return try Tables.decodeHeader(schema.headerJSON)
  }

  func tableState(_ path: SpacePath, ceiling: Int64) throws -> (TableHeader, [TableReplay.ReplayedRow]) {
    let key = id.key
    return try TableReplay.state(
      path,
      ceiling: ceiling,
      schemas: db.rows(TableSchemaVersionRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) && $0.rev.lte(ceiling) }.order { $0.rev }),
      journal: db.rows(TableRowRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) && $0.createdRev.lte(ceiling) }),
    )
  }

  func openPayload(_ path: SpacePath, rowID: Int64) throws -> [String: JSONValue] {
    let key = id.key
    guard let row = db.rows(TableRowRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) && $0.rowID.eq(rowID) && $0.deletedRev.is(nil) }).first,
          let object = JSONValue.parse(row.payload)?.object else { throw SpaceError.notFound("\(path.rawValue)#\(rowID)") }
    return Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.value) })
  }

  mutating func createTable(_ path: SpacePath, header: TableHeader, mtime: String, attribution: RevisionAttribution?) throws -> Int64 {
    if file(path) != nil || tableExists(path) { throw SpaceError.alreadyExists(path.rawValue) }
    let rev = try mintRevision(mtime, attribution: attribution)
    try ensureAncestorDirectories(path, rev: rev, mtime: mtime)
    let key = id.key
    try db.execute(TableNodeRow.insert { TableNodeRow(grp: key, path: path.rawValue, createdRev: rev) })
    try recordSchema(path, header: header, rev: rev)
    try db.execute(Tables.createMaterializedSQL(path, group: group, header: header))
    try syncSequence(path)
    try touchTableNode(path, rev: rev, mtime: mtime)
    return rev
  }

  mutating func alterTable(_ path: SpacePath, header: TableHeader, ifMatch: VersionToken?, allowDropColumns: Bool, mtime: String, attribution: RevisionAttribution?) throws -> Int64 {
    let old = try currentHeader(path)
    try LiveFS.checkIfMatch(ifMatch, head: file(path), path: path)
    let oldTypes = Dictionary(uniqueKeysWithValues: old.columns.map { ($0.name, $0.type) })
    for column in header.columns {
      if let oldType = oldTypes[column.name], oldType != column.type {
        throw SpaceError.columnTypeChanged("\(path.rawValue).\(column.name): \(oldType.rawValue) -> \(column.type.rawValue); drop and re-add the column instead")
      }
    }
    let oldNames = Set(old.columns.map(\.name)), newNames = Set(header.columns.map(\.name))
    if !allowDropColumns, !oldNames.isSubset(of: newNames) { throw SpaceError.invalidTableHeader("omitting a column requires allowDropColumns: true") }
    let rev = try mintRevision(mtime, attribution: attribution)
    try recordSchema(path, header: header, rev: rev)
    let table = Tables.quoted(group, path)
    for column in header.columns where !oldNames.contains(column.name) {
      try db.execute("ALTER TABLE \(table) ADD COLUMN \(Cells.quote(column.name)) \(Tables.sqlType(column.type))")
    }
    for column in old.columns where !newNames.contains(column.name) { try db.execute("ALTER TABLE \(table) DROP COLUMN \(Cells.quote(column.name))") }
    try touchTableNode(path, rev: rev, mtime: mtime)
    return rev
  }

  mutating func commitRows(_ path: SpacePath, edits: [RowEdit], mtime: String, attribution: RevisionAttribution?) throws -> RowCommit {
    let header = try currentHeader(path)
    let ops: [RowOp] = try edits.map {
      switch $0 {
      case let .insert(fields): .insert(try Cells.positional(fields, header: header, base: nil, path: path))
      case let .update(rowID, fields): .update(id: rowID, try Cells.positional(fields, header: header, base: openPayload(path, rowID: rowID), path: path))
      case let .delete(rowID): .delete(id: rowID)
      }
    }
    return try commitRows(path, ops: ops, mtime: mtime, attribution: attribution)
  }

  mutating func commitRows(_ path: SpacePath, ops: [RowOp], mtime: String, attribution: RevisionAttribution?) throws -> RowCommit {
    let header = try currentHeader(path), rev = try mintRevision(mtime, attribution: attribution)
    var ids: [Int64] = []
    for op in ops {
      switch op {
      case let .insert(cells):
        try insertMaterializedRow(path, header: header, rowID: nil, cells: cells)
        let rowID = db.one("SELECT last_insert_rowid()")!.integer!
        try recordRow(path, header: header, rowID: rowID, cells: cells, rev: rev)
        ids.append(rowID)
      case let .update(rowID, cells):
        let values = try Self.bindings(header, cells, path: path)
        try closeRow(path, rowID: rowID, rev: rev)
        try recordRow(path, header: header, rowID: rowID, cells: cells, rev: rev)
        if !header.columns.isEmpty {
          let assignments = header.columns.map { "\(Cells.quote($0.name)) = ?" }.joined(separator: ", ")
          try db.execute("UPDATE \(Tables.quoted(group, path)) SET \(assignments) WHERE id = ?", values + [.integer(rowID)])
        }
      case let .delete(rowID):
        try closeRow(path, rowID: rowID, rev: rev)
        try db.execute("DELETE FROM \(Tables.quoted(group, path)) WHERE id = ?", .integer(rowID))
      }
    }
    try touchTableNode(path, rev: rev, mtime: mtime)
    return RowCommit(rev: Rev(Int(rev)), ids: ids)
  }

  mutating func recordSchema(_ path: SpacePath, header: TableHeader, rev: Int64) throws {
    let key = id.key, json = Tables.encodeHeader(header)
    try db.execute(TableSchemaVersionRow.insert { TableSchemaVersionRow(grp: key, path: path.rawValue, rev: rev, headerJSON: json) })
  }

  mutating func recordRow(_ path: SpacePath, header: TableHeader, rowID: Int64, cells: [JSONValue], rev: Int64) throws {
    let key = id.key, payload = Tables.payloadJSON(header: header, cells: cells)
    try db.execute(TableRowRow.insert { TableRowRow(grp: key, path: path.rawValue, rowID: rowID, createdRev: rev, deletedRev: nil, payload: payload) })
  }

  private mutating func closeRow(_ path: SpacePath, rowID: Int64, rev: Int64) throws {
    _ = try openPayload(path, rowID: rowID)
    let key = id.key
    try db.execute(TableRowRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) && $0.rowID.eq(rowID) && $0.deletedRev.is(nil) }.update { $0.deletedRev = #bind(rev) })
  }

  mutating func retireTable(_ path: SpacePath, rev: Int64) throws {
    try db.execute("DROP TABLE IF EXISTS \(Tables.quoted(group, path))")
    let key = id.key
    try db.execute(TableNodeRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.delete())
    try db.execute(TableRowRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) && $0.deletedRev.is(nil) }.update { $0.deletedRev = #bind(rev) })
  }

  mutating func restoreTable(_ path: SpacePath, ceiling: Int64, rev: Int64, mtime: String) throws {
    let (header, rows) = try tableState(path, ceiling: ceiling)
    try retireTable(path, rev: rev)
    try installTable(path, header: header, rows: rows, rev: rev)
    try touchTableNode(path, rev: rev, mtime: mtime, op: .checkout, aux: String(ceiling))
  }

  mutating func installTable(_ path: SpacePath, header: TableHeader, rows: [TableReplay.ReplayedRow], rev: Int64) throws {
    let key = id.key
    try db.execute(TableNodeRow.insert { TableNodeRow(grp: key, path: path.rawValue, createdRev: rev) })
    try recordSchema(path, header: header, rev: rev)
    try db.execute(Tables.createMaterializedSQL(path, group: group, header: header))
    for row in rows {
      let cells = header.columns.map { row.cells[$0.name] ?? .null }
      try insertMaterializedRow(path, header: header, rowID: row.id, cells: cells)
      try recordRow(path, header: header, rowID: row.id, cells: cells, rev: rev)
    }
    try syncSequence(path)
  }

  mutating func insertMaterializedRow(_ path: SpacePath, header: TableHeader, rowID: Int64?, cells: [JSONValue]) throws {
    let values = try Self.bindings(header, cells, path: path)
    var columns = header.columns.map { Cells.quote($0.name) }
    var args = values
    if let rowID { columns.insert("id", at: 0); args.insert(.integer(rowID), at: 0) }
    let table = Tables.quoted(group, path)
    if columns.isEmpty { try db.execute("INSERT INTO \(table) DEFAULT VALUES") } else {
      try db.execute("INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(args.map { _ in "?" }.joined(separator: ", ")))", args)
    }
  }

  mutating func syncSequence(_ path: SpacePath) throws {
    let key = id.key
    let maxID = db.rows(TableRowRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.select { $0.rowID.max() }).first! ?? 0
    let name = Tables.realName(group, path)
    try db.execute("DELETE FROM sqlite_sequence WHERE name = ?", .text(name))
    if maxID > 0 { try db.execute("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", .text(name), .integer(maxID)) }
  }

  func liveRowIDs(_ path: SpacePath) -> [Int64] {
    db.rows("SELECT id FROM \(Tables.quoted(group, path)) ORDER BY id").map { $0[0].integer! }
  }

  private static func bindings(_ header: TableHeader, _ cells: [JSONValue], path: SpacePath) throws -> [Value] {
    guard cells.count == header.columns.count else { throw SpaceError.columnCountMismatch(path.rawValue) }
    return try zip(header.columns, cells).map { column, value in
      if column.type == .blob, case let .string(text) = value {
        guard let bytes = Data(base64Encoded: text) else { throw SpaceError.invalidCellValue("blob cell expects base64, got \(text)") }
        return .blob(Array(bytes))
      }
      if column.type == .json, value != .null { return .text(value.jsonString(sortedKeys: true)) }
      switch value {
      case .null: return .null
      case let .bool(flag): return .integer(flag ? 1 : 0)
      case let .integer(int): return .integer(Int64(int))
      case let .number(double): return .real(double)
      case let .string(text): return .text(text)
      case .array, .object: return .text(value.jsonString(sortedKeys: true))
      }
    }
  }
}
