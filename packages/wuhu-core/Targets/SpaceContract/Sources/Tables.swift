import Contract
import JSONValue

@Contract
public enum ColumnType: String, Codable, Equatable, Sendable {
  case string
  case integer
  case number
  case boolean
  case json
}

@Contract
public struct ColumnSpec: Codable, Equatable, Sendable {
  public let name: String
  public let type: ColumnType
}

@Contract
public struct TableHeader: Codable, Equatable, Sendable {
  public let columns: [ColumnSpec]
}

@Contract
public enum RowOp: Codable, Equatable, Sendable {
  case insert(values: [JSONValue])
  case update(row: Int, values: [JSONValue])
  case delete(row: Int)
}
