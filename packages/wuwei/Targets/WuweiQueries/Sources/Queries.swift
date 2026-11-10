#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import StructuredQueriesCore
import Wuwei

/// A table whose rows belong to addressables: its schema declares ``Wuwei/Addressable/ownerColumn`` and its Swift type leaves that column out, so `cell()` fills it in. Selects, updates and deletes keep to the caller's own rows; `unscoped` reaches past that, for reads.
public protocol Owned: Table where DefaultScope == Where<Self> {}

extension Owned {
  public static var all: Where<Self> {
    Self.where { _ in SQLQueryExpression<Bool>("\(quote: tableName).\(quote: "owner") = cell()") }
  }
}

extension Database {
  public func rows<S: SelectStatement>(_ statement: S) -> [S.From.QueryOutput] where S.QueryValue == (), S.Joins == () {
    decode(S.From.self, statement.query, rows)
  }

  public func rows<S: StructuredQueriesCore.Statement>(_ statement: S) -> [S.QueryValue.QueryOutput] where S.QueryValue: QueryRepresentable {
    decode(S.QueryValue.self, statement.query, rows)
  }

  public mutating func execute<S: StructuredQueriesCore.Statement>(_ statement: S) throws(ConstraintViolation) where S.QueryValue == () {
    let (sql, arguments) = prepare(statement.query)
    try execute(sql, arguments)
  }
}

extension JobDatabase {
  public func rows<S: SelectStatement>(_ statement: S) -> [S.From.QueryOutput] where S.QueryValue == (), S.Joins == () {
    decode(S.From.self, statement.query, rows)
  }

  public func rows<S: StructuredQueriesCore.Statement>(_ statement: S) -> [S.QueryValue.QueryOutput] where S.QueryValue: QueryRepresentable {
    decode(S.QueryValue.self, statement.query, rows)
  }

  public mutating func execute<S: StructuredQueriesCore.Statement>(_ statement: S) throws where S.QueryValue == () {
    let (sql, arguments) = prepare(statement.query)
    try execute(sql, arguments)
  }
}

private func prepare(_ query: QueryFragment) -> (String, [Value]) {
  let (sql, bindings) = query.prepare { _ in "?" }
  return (sql.isEmpty ? "SELECT 1 WHERE 0" : sql, bindings.map(\.value))
}

/// A row that does not decode as its statement says is a bug, so it traps.
private func decode<Output: QueryRepresentable>(_: Output.Type, _ query: QueryFragment, _ rows: (String, [Value]) -> [Row]) -> [Output.QueryOutput] {
  let (sql, arguments) = prepare(query)
  return rows(sql, arguments).map { row in
    var decoder = RowDecoder(row: row)
    do { return try Output(decoder: &decoder).queryOutput } catch { preconditionFailure("\(sql): \(error)") }
  }
}

private struct RowDecoder: QueryDecoder {
  struct Mismatch: Error {
    let column: Int
    let value: Value
    let type: Any.Type
  }

  let row: Row
  var column = 0

  private mutating func next<T>(_ type: T.Type, _ convert: (Value) -> T?) throws -> T? {
    defer { column += 1 }
    let value = row[column]
    if value == .null { return nil }
    guard let converted = convert(value) else { throw Mismatch(column: column, value: value, type: type) }
    return converted
  }

  mutating func decode(_: [UInt8].Type) throws -> [UInt8]? {
    try next([UInt8].self) { $0.blob }
  }

  mutating func decode(_: Double.Type) throws -> Double? {
    try next(Double.self) { if case let .real(value) = $0 { value } else { $0.integer.map(Double.init) } }
  }

  mutating func decode(_: Int64.Type) throws -> Int64? {
    try next(Int64.self) { $0.integer }
  }

  mutating func decode(_: UInt64.Type) throws -> UInt64? {
    try next(UInt64.self) { $0.integer.flatMap(UInt64.init(exactly:)) }
  }

  mutating func decode(_: String.Type) throws -> String? {
    try next(String.self) { $0.text }
  }

  mutating func decode(_: Bool.Type) throws -> Bool? {
    try next(Bool.self) { $0.integer.map { $0 != 0 } }
  }

  mutating func decode(_: Int.Type) throws -> Int? {
    try next(Int.self) { $0.integer.flatMap(Int.init(exactly:)) }
  }

  mutating func decode(_: Date.Type) throws -> Date? {
    try next(Date.self) { $0.text.flatMap { try? iso8601.parse($0) } }
  }

  mutating func decode(_: UUID.Type) throws -> UUID? {
    try next(UUID.self) { $0.text.flatMap(UUID.init(uuidString:)) }
  }
}

private let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

extension QueryBinding {
  fileprivate var value: Value {
    switch self {
    case let .blob(value): .blob(value)
    case let .bool(value): .integer(value ? 1 : 0)
    case let .date(value): .text(iso8601.format(value))
    case let .double(value): .real(value)
    case let .int(value): .integer(value)
    case .null: .null
    case let .text(value): .text(value)
    case let .uint(value): .integer(Int64(exactly: value) ?? { preconditionFailure("\(value) does not fit an INTEGER") }())
    case let .uuid(value): .text(value.uuidString.lowercased())
    case let .invalid(error): preconditionFailure("an argument does not bind: \(error.underlyingError)")
    }
  }
}
