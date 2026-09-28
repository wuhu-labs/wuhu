import Foundation
import GRDB
import JSONValue
import struct OrderedCollections.OrderedDictionary
import struct SpaceFS.SpacePath

enum Cells {
  static func binding(_ value: JSONValue, type: TableColumn.ColumnType) throws -> DatabaseValue {
    if type == .blob, case let .string(text) = value {
      guard let data = Data(base64Encoded: text) else {
        throw SpaceError.invalidCellValue("blob cell expects base64, got \(text)")
      }
      return data.databaseValue
    }
    // A json column stores the canonical serialization for every value (a JSON
    // string "x" is stored as "\"x\"", not "x") so rehydration is a plain parse.
    if type == .json, value != .null {
      return value.jsonString(sortedKeys: true).databaseValue
    }
    return parameter(value)
  }

  /// A bound query parameter from its wire form: a scalar or `{"blob": base64}`.
  static func typedParameter(_ value: JSONValue, index: Int) throws -> DatabaseValue {
    switch value {
    case .null, .bool, .integer, .number, .string:
      return parameter(value)
    case let .object(object):
      if object.count == 1, case let .string(text)? = object["blob"] {
        guard let data = Data(base64Encoded: text) else {
          throw SpaceError.invalidCellValue("parameter \(index + 1): blob expects base64")
        }
        return data.databaseValue
      }
      throw SpaceError.invalidCellValue("parameter \(index + 1): expected a scalar or {\"blob\": base64}")
    case .array:
      throw SpaceError.invalidCellValue("parameter \(index + 1): expected a scalar or {\"blob\": base64}")
    }
  }

  /// Named wire cells to a positional row: unnamed columns come from `base`
  /// (null when inserting), each named value must fit its column's type.
  static func positional(
    _ fields: OrderedDictionary<String, JSONValue>, header: TableHeader, base: [String: JSONValue]?, path: SpacePath,
  ) throws -> [JSONValue] {
    let names = Set(header.columns.map(\.name))
    if let unknown = fields.keys.first(where: { !names.contains($0) }) {
      throw SpaceError.invalidCellValue("\(path.rawValue) has no column \(unknown)")
    }
    return try header.columns.map { column in
      guard let value = fields[column.name] else { return base?[column.name] ?? .null }
      return try positional(value, type: column.type, column: "\(path.rawValue).\(column.name)")
    }
  }

  private static func positional(_ value: JSONValue, type: TableColumn.ColumnType, column: String) throws -> JSONValue {
    let fits: JSONValue? = switch (type, value) {
    case (_, .null): .null
    case (.text, .string): value
    case (.integer, .integer): value
    case let (.integer, .number(double)):
      double.rounded() == double && abs(double) <= 9_007_199_254_740_991 ? .integer(Int(double)) : nil
    case (.real, .integer), (.real, .number): value
    case (.boolean, .bool): value
    case let (.blob, .object(object)):
      if object.count == 1, case let .string(text)? = object["blob"], Data(base64Encoded: text) != nil { .string(text) } else { nil }
    case let (.json, .object(object)):
      if object.count == 1, let inner = object["json"] { inner } else { nil }
    case (.json, .bool), (.json, .integer), (.json, .number), (.json, .string), (.json, .array): value
    default: nil
    }
    guard let fits else {
      throw SpaceError.invalidCellValue("\(column) is \(type.rawValue) and cannot hold \(value.jsonString(sortedKeys: true))")
    }
    return fits
  }

  static func parameter(_ value: JSONValue) -> DatabaseValue {
    switch value {
    case .null: .null
    case let .bool(flag): Int64(flag ? 1 : 0).databaseValue
    case let .integer(int): Int64(int).databaseValue
    case let .number(double): double.databaseValue
    case let .string(text): text.databaseValue
    case .array, .object: value.jsonString(sortedKeys: true).databaseValue
    }
  }

  static func cell(from value: DatabaseValue) -> Cell {
    switch value.storage {
    case .null: .null
    case let .int64(int): .integer(int)
    case let .double(double): .real(double)
    case let .string(text): .text(text)
    case let .blob(data): .blob(Array(data))
    }
  }

  static func quote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
