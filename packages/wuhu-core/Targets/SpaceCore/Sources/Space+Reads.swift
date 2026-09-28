#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import JSONValue
import SpaceSQL

extension Space {
  /// What `principal` may read: its acting group and every group that group reads.
  public func readScope(for principal: Principal, viewer: String? = nil) async throws -> ReadScope {
    try await ReadScope(acting: principal.group, readable: reads(principal.group), viewer: viewer, member: principal.member)
  }

  public func query(
    _ sql: String,
    arguments: [JSONValue] = [],
    byteLimit: Int? = nil,
    viewer: String? = nil,
    as principal: Principal,
  ) async throws -> Rows {
    let scope = try await readScope(for: principal, viewer: viewer)
    return try await Self.read(sql, arguments: arguments.map(Cells.parameter), byteLimit: byteLimit, scope: scope, in: reads)
  }

  /// `sql` with typed bound parameters: each a scalar or `{"blob": base64}`,
  /// anything else refused.
  public func query(
    _ sql: String,
    parameters: [JSONValue],
    byteLimit: Int? = nil,
    viewer: String? = nil,
    as principal: Principal,
  ) async throws -> Rows {
    let arguments = try Self.bound(parameters)
    let scope = try await readScope(for: principal, viewer: viewer)
    return try await Self.read(sql, arguments: arguments, byteLimit: byteLimit, scope: scope, in: reads)
  }

  /// Typed parameters as SQLite values, or the refusal a typed query meets.
  public static func bound(_ parameters: [JSONValue]) throws -> [DatabaseValue] {
    try parameters.enumerated().map { try Cells.typedParameter($1, index: $0) }
  }

  /// The space tables `sql` reads, or the refusal running it would meet.
  @discardableResult
  public func validateQuery(_ sql: String, as principal: Principal) async throws -> ReadTables {
    let scope = try await readScope(for: principal)
    return try await Self.tables(sql, scope: scope, in: reads)
  }

  public static func callsViewer(_ sql: String) -> Bool {
    SQLText.identifier(in: sql, among: ["viewer"]) != nil
  }

  static func read(
    _ sql: String,
    arguments: [DatabaseValue] = [],
    byteLimit: Int? = nil,
    scope: ReadScope,
    in reads: ReadPool,
  ) async throws -> Rows {
    let rows: ReadRows
    do {
      (rows, _) = try await reads.run(sql, arguments: arguments, byteLimit: byteLimit, scope: scope)
    } catch let error as ReadError {
      throw SpaceError(error)
    }
    return Rows(columns: rows.columns, decltypes: rows.decltypes, rows: rows.rows.map { $0.map(Cells.cell(from:)) })
  }

  static func tables(_ sql: String, scope: ReadScope, in reads: ReadPool) async throws -> ReadTables {
    do {
      return try await reads.tables(sql, scope: scope)
    } catch let error as ReadError {
      throw SpaceError(error)
    }
  }
}

extension SpaceError {
  init(_ error: ReadError) {
    self = switch error {
    case .notReadOnly: .queryNotReadOnly
    case let .forbidden(tables): .queryForbiddenTable(tables)
    case let .unknownRelation(name): .unknownRelation(name)
    case let .tooLarge(byteLimit): .queryResultTooLarge(byteLimit: byteLimit)
    }
  }
}
