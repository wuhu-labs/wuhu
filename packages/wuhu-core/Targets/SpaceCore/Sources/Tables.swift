#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS
import Wuwei

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

  static func createMaterializedSQL(_ path: SpacePath, group: GroupID, header: TableHeader) -> String {
    let columns = header.columns.map { "\(Cells.quote($0.name)) \(sqlType($0.type))" }
    let body = (["\"id\" INTEGER PRIMARY KEY AUTOINCREMENT"] + columns).joined(separator: ", ")
    return "CREATE TABLE \(quoted(group, path)) (\(body))"
  }

  // BOOLEAN and JSON_TEXT are recognized decltypes, not SQLite keywords: the
  // wire encoder rehydrates result cells by them (JSON_TEXT contains "TEXT" so
  // json columns keep TEXT affinity and never get numeric-coerced).
  static func sqlType(_ type: TableColumn.ColumnType) -> String {
    switch type {
    case .text: "TEXT"
    case .integer: "INTEGER"
    case .real: "REAL"
    case .blob: "BLOB"
    case .boolean: "BOOLEAN"
    case .json: "JSON_TEXT"
    }
  }

  static func payloadJSON(header: TableHeader, cells: [JSONValue]) -> String {
    let pairs = zip(header.columns, cells)
      .map { (name: $0.name, json: $1.jsonString(sortedKeys: true)) }
      .sorted { $0.name < $1.name }
    let body = pairs.map { "\(JSONValue.string($0.name).jsonString()):\($0.json)" }.joined(separator: ",")
    return "{\(body)}"
  }
}
