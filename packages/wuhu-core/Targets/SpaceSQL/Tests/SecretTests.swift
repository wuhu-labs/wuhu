import Foundation
import GRDB
@testable import SpaceSQL
import Testing

// The views stand on two names a caller never learns: the schema the space
// file is attached under and the inner views that carry the filters. Nothing
// a statement returns or fails with names either, and knowing them gets a
// statement past no filter.
@Suite struct SecretTests {
  static let secrets = ReadConnection.Secrets(schema: "5ec7e7a", views: "b1eedb1eed")
  static let schema = "s5ec7e7a"
  static let innerSessions = "__vb1eedb1eed_0"
  static let hiding = ViewCatalog { table, _ in table == "sessions" ? "id <> 'hidden'" : nil }

  @Test func noListingNamesTheSchemaOrTheViews() throws {
    let file = try Fixture()
    let connection = try ReadConnection(path: file.path, catalog: Self.hiding, secrets: Self.secrets)

    for sql in [
      "SELECT * FROM sqlite_temp_master",
      "SELECT * FROM temp.sqlite_schema",
      "SELECT sql FROM sqlite_temp_schema",
      "PRAGMA database_list",
      "SELECT * FROM pragma_database_list",
      "SELECT name FROM pragma_database_list()",
      "SELECT * FROM pragma_table_list",
      "SELECT * FROM pragma_table_list()",
      "PRAGMA table_list",
      "SELECT * FROM pragma_table_info('sessions')",
      "SELECT * FROM pragma_view_list",
      "SELECT * FROM sqlite_master",
      "SELECT * FROM \(Self.schema).sqlite_master",
      "SELECT sql FROM temp.sqlite_master WHERE name = 'sessions'",
    ] {
      try sealed(connection, sql, refusedAs: ReadError.self)
    }
  }

  @Test func noPlanIsExplained() throws {
    let file = try Fixture()
    let connection = try ReadConnection(path: file.path, catalog: Self.hiding, secrets: Self.secrets)

    for sql in [
      "EXPLAIN SELECT * FROM sessions",
      "EXPLAIN QUERY PLAN SELECT * FROM sessions",
      "explain query plan SELECT count(*) FROM sessions",
      "/* c */ EXPLAIN SELECT 1",
    ] {
      #expect(throws: ReadError.notReadOnly) { try connection.run(sql, arguments: [], byteLimit: nil, scope: .shared()) }
      try sealed(connection, sql, refusedAs: ReadError.self)
    }
  }

  @Test func errorsNameTheTablesNotTheViews() throws {
    let file = try Fixture()
    let connection = try ReadConnection(path: file.path, catalog: Self.hiding, secrets: Self.secrets)

    for sql in [
      "SELECT nope FROM sessions",
      "SELECT sessions.nope FROM sessions",
      "SELECT * FROM sessions WHERE",
      "SELECT * FROM sessions s JOIN sessions t USING (nope)",
      "SELECT json('{' || id) FROM sessions",
      "SELECT * FROM sessions WHERE id = ?",
      "SELECT * FROM main.sessions",
      "SELECT * FROM temp.nope",
      "SELECT * FROM \(Self.innerSessions)x",
    ] {
      try sealed(connection, sql, refusedAs: (any Error).self)
    }
  }

  @Test func aBrokenFilterIsReportedWithoutItsViews() throws {
    let file = try Fixture()
    let broken = ViewCatalog { table, _ in table == "sessions" ? "nope = 1" : nil }
    let connection = try ReadConnection(path: file.path, catalog: broken, secrets: Self.secrets)
    try sealed(connection, "SELECT * FROM sessions", refusedAs: (any Error).self)

    let failing = ViewCatalog { table, _ in table == "sessions" ? "json('{' || id) IS NOT NULL" : nil }
    let other = try ReadConnection(path: file.path, catalog: failing, secrets: Self.secrets)
    try sealed(other, "SELECT * FROM sessions", refusedAs: (any Error).self)
  }

  @Test func aDroppedColumnIsReportedWithoutItsViews() async throws {
    let file = try Fixture()
    let filtering = ViewCatalog { table, _ in table == "sessions" ? "flag = 1" : nil }
    let connection = try ReadConnection(path: file.path, catalog: Self.hiding, secrets: Self.secrets)
    let filtered = try ReadConnection(path: file.path, catalog: filtering, secrets: Self.secrets)
    try sealed(connection, "SELECT flag FROM sessions")
    try sealed(filtered, "SELECT flag FROM sessions")

    let writer = try DatabaseQueue(path: file.path)
    try await writer.write { db in try db.execute(sql: "ALTER TABLE sessions DROP COLUMN flag") }

    try sealed(connection, "SELECT flag FROM sessions", refusedAs: (any Error).self)
    try sealed(filtered, "SELECT id FROM sessions", refusedAs: (any Error).self)
    try sealed(connection, "SELECT * FROM sessions")
  }

  @Test func whatAStatementReturnsNamesOnlyTables() throws {
    let file = try Fixture()
    let connection = try ReadConnection(path: file.path, catalog: Self.hiding, secrets: Self.secrets)

    for sql in [
      "SELECT * FROM sessions",
      "SELECT sessions.* FROM sessions",
      "SELECT * FROM sessions, (SELECT * FROM sessions)",
      "SELECT * FROM (SELECT * FROM sessions) UNION ALL SELECT * FROM sessions",
      "SELECT count(*) FROM sessions",
      "SELECT json_group_array(json_object('id', id)) FROM sessions",
    ] {
      let tables = try sealed(connection, sql)
      #expect(tables == ["sessions"], "\(sql)")
    }
  }

  // A statement that writes either secret does not compile.
  @Test func aLeakedNameIsRefusedAsWritten() throws {
    let file = try Fixture()
    let connection = try ReadConnection(path: file.path, catalog: Self.hiding, secrets: Self.secrets)

    for sql in Self.bypasses + [
      "SELECT id FROM temp.\(Self.innerSessions)",
      "SELECT 1 FROM sessions WHERE id = 'S5EC7E7A'",
    ] {
      #expect(throws: ReadError.forbidden("main"), "\(sql)") {
        try connection.run(sql, arguments: [], byteLimit: nil, scope: .shared())
      }
    }
  }

  // Past the screen, the schema name alone reaches no row the filter hides:
  // a column of a space table is read only through an inner view, and a read
  // of no column only where the table has no filter. The accessor SQLite
  // reports is a name as written, so a CTE named after an inner view passes
  // the gate; that one takes both secrets and the screen stops it.
  @Test func aLeakedSchemaGetsPastNoFilter() throws {
    let file = try Fixture()
    let connection = try ReadConnection(
      path: file.path, catalog: Self.hiding, secrets: Self.secrets, screensText: false,
    )

    for sql in Self.bypasses {
      #expect(throws: ReadError.forbidden("sessions"), "\(sql)") {
        try connection.run(sql, arguments: [], byteLimit: nil, scope: .shared())
      }
    }
    let (rows, _) = try connection.run(
      "SELECT id FROM temp.\(Self.innerSessions)", arguments: [], byteLimit: nil, scope: .shared(),
    )
    #expect(rows.rows == [["a".databaseValue]])
  }

  static let bypasses: [String] = {
    let base = "\"\(schema)\".sessions"
    return [
      "SELECT id FROM \(base)",
      "SELECT * FROM \(base) WHERE id = 'hidden'",
      "SELECT count(*) FROM \(base)",
      "SELECT count(*) FROM \(base) WHERE id = 'hidden'",
      "SELECT (SELECT count(*) FROM \(base))",
      "SELECT EXISTS (SELECT 1 FROM \(base) WHERE id = 'hidden')",
      "SELECT v.id FROM sessions v JOIN \(base) s ON s.id <> v.id",
      "WITH sessions AS (SELECT * FROM \(base)) SELECT id FROM sessions",
      "WITH c AS (SELECT * FROM \(base)) SELECT count(*) FROM c",
      "SELECT value FROM json_each((SELECT json_group_array(id) FROM \(base)))",
    ]
  }()

  @discardableResult
  private func sealed(
    _ connection: ReadConnection,
    _ sql: String,
    sourceLocation: SourceLocation = #_sourceLocation,
  ) throws -> Set<String> {
    let (rows, tables) = try connection.run(sql, arguments: [], byteLimit: nil, scope: .shared())
    let text = "\(rows.columns) \(rows.decltypes) \(rows.rows) \(tables.names)"
    #expect(!leaks(text), "\(sql): \(text)", sourceLocation: sourceLocation)
    return tables.names
  }

  private func sealed<E: Error>(
    _ connection: ReadConnection,
    _ sql: String,
    refusedAs: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation,
  ) throws {
    do {
      _ = try connection.run(sql, arguments: [], byteLimit: nil, scope: .shared())
      Issue.record("\(sql) ran", sourceLocation: sourceLocation)
    } catch {
      #expect(error is E, "\(sql): \(error)", sourceLocation: sourceLocation)
      #expect(!leaks("\(error) \(String(reflecting: error))"), "\(sql): \(error)", sourceLocation: sourceLocation)
    }
    do {
      let tables = try connection.tables(sql, scope: .shared())
      #expect(!leaks("\(tables.names)"), "\(sql)", sourceLocation: sourceLocation)
    } catch {
      #expect(!leaks("\(error) \(String(reflecting: error))"), "\(sql): \(error)", sourceLocation: sourceLocation)
    }
  }

  private func leaks(_ text: String) -> Bool {
    text.contains("5ec7e7a") || text.contains("b1eed")
  }
}
