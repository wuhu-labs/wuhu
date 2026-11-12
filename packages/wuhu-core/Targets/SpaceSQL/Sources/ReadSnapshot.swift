#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import StructuredQueriesCore

/// Server-authored reads used to resolve a scope inside the caller statement's SQLite snapshot. These reads bypass the sandbox; caller SQL never belongs here.
public struct ReadSnapshot {
  let read: (String, String, [DatabaseValue]) throws -> ReadRows

  public func rows<S: SelectStatement>(_ statement: S) throws -> [S.From.QueryOutput] where S.QueryValue == (), S.Joins == () {
    let (sql, bindings) = statement.query.prepare { _ in "?" }
    return try read(S.From.tableName, sql, bindings.map(\.databaseValue)).rows.map { row in
      var decoder = SnapshotDecoder(row: row)
      return try S.From(decoder: &decoder).queryOutput
    }
  }
}

private struct SnapshotDecoder: QueryDecoder {
  let row: [DatabaseValue]
  var column = 0

  private mutating func next<T: DatabaseValueConvertible>(_ type: T.Type) throws -> T? {
    defer { column += 1 }
    if row[column].isNull { return nil }
    guard let value = T.fromDatabaseValue(row[column]) else { preconditionFailure("scope row does not decode as \(type)") }
    return value
  }

  mutating func decode(_: [UInt8].Type) throws -> [UInt8]? { try next(Data.self).map(Array.init) }
  mutating func decode(_: Double.Type) throws -> Double? { try next(Double.self) }
  mutating func decode(_: Int64.Type) throws -> Int64? { try next(Int64.self) }
  mutating func decode(_: UInt64.Type) throws -> UInt64? { try next(UInt64.self) }
  mutating func decode(_: String.Type) throws -> String? { try next(String.self) }
  mutating func decode(_: Bool.Type) throws -> Bool? { try next(Bool.self) }
  mutating func decode(_: Int.Type) throws -> Int? { try next(Int.self) }
  mutating func decode(_: Date.Type) throws -> Date? { try next(Date.self) }
  mutating func decode(_: UUID.Type) throws -> UUID? { try next(UUID.self) }
}

extension QueryBinding {
  fileprivate var databaseValue: DatabaseValue {
    switch self {
    case let .blob(value): Data(value).databaseValue
    case let .bool(value): value.databaseValue
    case let .date(value): value.databaseValue
    case let .double(value): value.databaseValue
    case let .int(value): value.databaseValue
    case .null: .null
    case let .text(value): value.databaseValue
    case let .uint(value): value.databaseValue
    case let .uuid(value): value.uuidString.lowercased().databaseValue
    case let .invalid(error): preconditionFailure("scope argument does not bind: \(error)")
    }
  }
}
