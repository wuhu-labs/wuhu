#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue

extension Rows {
  public var json: JSONValue {
    .object([
      "columns": .array(columns.map(JSONValue.string)),
      "rows": .array(rows.map { row in .array(zip(row, decltypes).map { Self.cell($0, decltype: $1) }) }),
    ])
  }

  private static func cell(_ cell: Cell, decltype: String?) -> JSONValue {
    switch (decltype, cell) {
    case let ("JSON_TEXT", .text(stored)):
      guard let value = JSONValue.parse(stored) else {
        return .string(stored)
      }
      return value
    case let ("BOOLEAN", .integer(flag)):
      return .bool(flag != 0)
    case (_, .null): return .null
    case let (_, .integer(value)): return .integer(Int(value))
    case let (_, .real(value)): return .number(value)
    case let (_, .text(value)): return .string(value)
    case let (_, .blob(bytes)): return .string(Data(bytes).base64EncodedString())
    }
  }
}
