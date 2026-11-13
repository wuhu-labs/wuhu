#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import StructuredQueriesCore

/// Server-authored reads used to resolve a scope inside the caller statement's SQLite snapshot. These reads bypass the sandbox; caller SQL never belongs here.
public struct ReadSnapshot {
  let read: (String, String, [SQLValue]) throws -> ReadRows

  public func rows<S: SelectStatement>(_ statement: S) throws -> [S.From.QueryOutput] where S.QueryValue == (), S.Joins == () {
    let (sql, bindings) = statement.query.prepare { _ in "?" }
    return try read(S.From.tableName, sql, bindings.map(\.sqlValue)).rows.map { row in
      var decoder = SnapshotDecoder(row: row)
      return try S.From(decoder: &decoder).queryOutput
    }
  }
}

private struct SnapshotDecoder: QueryDecoder {
  let row: [SQLValue]
  var column = 0

  private mutating func next<T>(_ type: T.Type, _ convert: (SQLValue) -> T?) throws -> T? {
    defer { column += 1 }
    let value = row[column]
    if value == .null { return nil }
    guard let converted = convert(value) else { preconditionFailure("scope row column \(column) does not decode as \(type)") }
    return converted
  }

  mutating func decode(_: [UInt8].Type) throws -> [UInt8]? {
    try next([UInt8].self) { if case let .blob(value) = $0 { value } else { nil } }
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
  fileprivate var sqlValue: SQLValue {
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
    case let .invalid(error): preconditionFailure("scope argument does not bind: \(error)")
    }
  }
}
