#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct OrderedCollections.OrderedDictionary
import struct SpaceFS.SpacePath
import SpaceSQL

enum Cells {
  /// A bound query parameter from its wire form: a scalar or `{"blob": base64}`.
  static func typedParameter(_ value: JSONValue, index: Int) throws -> SQLValue {
    switch value {
    case .null, .bool, .integer, .number, .string:
      return parameter(value)
    case let .object(object):
      if object.count == 1, case let .string(text)? = object["blob"] {
        guard let data = Data(base64Encoded: text) else {
          throw SpaceError.invalidCellValue("parameter \(index + 1): blob expects base64")
        }
        return .blob(Array(data))
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

  static func parameter(_ value: JSONValue) -> SQLValue {
    switch value {
    case .null: .null
    case let .bool(flag): .integer(flag ? 1 : 0)
    case let .integer(int): .integer(Int64(int))
    case let .number(double): .real(double)
    case let .string(text): .text(text)
    case .array, .object: .text(value.jsonString(sortedKeys: true))
    }
  }

  static func cell(from value: SQLValue) -> Cell {
    switch value {
    case .null: .null
    case let .integer(int): .integer(int)
    case let .real(double): .real(double)
    case let .text(text): .text(text)
    case let .blob(bytes): .blob(bytes)
    }
  }

  static func quote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
