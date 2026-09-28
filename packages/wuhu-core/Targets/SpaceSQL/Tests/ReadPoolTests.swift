import Foundation
import GRDB
import SpaceSQL
import Testing

// The isolation the view layer promises, on a catalog that hides one row of
// `sessions`: no statement a caller can write reaches that row, and nothing
// outside the views, by any route SQLite offers.
@Suite struct ReadPoolTests {
  static let hiding = ViewCatalog { table, _ in table == "sessions" ? "id <> 'hidden'" : nil }

  @Test func theViewsShowOnlyTheRowsTheCatalogAdmits() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, catalog: Self.hiding)

    #expect(try await column(pool, "SELECT id FROM sessions ORDER BY id") == ["a"])
    #expect(try await column(pool, "SELECT count(*) FROM sessions") == ["1"])
    #expect(try await column(pool, "SELECT id FROM temp.sessions") == ["a"])
    let (rows, tables) = try await pool.run("SELECT flag, j FROM sessions", scope: .shared())
    #expect(rows.columns == ["flag", "j"])
    #expect(rows.decltypes == ["BOOLEAN", "JSON_TEXT"])
    #expect(tables.names == ["sessions"])
  }

  // The space file is not `main`: a qualified name finds nothing, and a CTE
  // that shadows a view reads the view.
  @Test func noNameReachesTheSpaceTablesPastTheViews() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, catalog: Self.hiding)

    await refused(pool, "SELECT count(*) FROM main.sessions", .unknownRelation("main.sessions"))
    await refused(
      pool, "WITH sessions AS (SELECT * FROM main.sessions) SELECT count(*) FROM sessions",
      .unknownRelation("main.sessions"),
    )
    #expect(try await column(pool, "WITH s AS (SELECT * FROM sessions) SELECT count(*) FROM s") == ["1"])
    #expect(try await column(pool, "SELECT count(*) FROM (SELECT * FROM sessions)") == ["1"])
    #expect(try await column(pool, "SELECT (SELECT count(*) FROM sessions) + 0") == ["1"])
    await refused(pool, "SELECT name FROM pragma_database_list", .forbidden("pragma_database_list"))
  }

  @Test func everyOtherRouteToABaseTableIsForbidden() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, catalog: Self.hiding)

    await refused(pool, "SELECT * FROM other", .forbidden("other"))
    await refused(pool, "SELECT count(*) FROM other", .forbidden("other"))
    await refused(pool, "SELECT * FROM temp.sqlite_master", .forbidden("sqlite_temp_master"))
    await refused(pool, "SELECT * FROM sqlite_temp_schema", .forbidden("sqlite_temp_master"))
    await refused(pool, "SELECT * FROM sqlite_master", .forbidden("sqlite_master"))
    await refused(pool, "SELECT * FROM pragma_table_list", .forbidden("pragma_table_list"))
    await refused(pool, "SELECT count(*) FROM pragma_table_list", .forbidden("pragma_table_list"))
    await refused(
      pool, "SELECT * FROM json_each((SELECT group_concat(n) FROM other))", .forbidden("other"),
    )
    #expect(try await column(pool, "SELECT value FROM json_each((SELECT json_group_array(id) FROM sessions))") == ["a"])
    // macOS builds SQLite without extension loading; where it exists, the gate refuses it.
    await #expect(throws: (any Error).self) { _ = try await pool.run("SELECT load_extension('x')", scope: .shared()) }
    await refused(pool, "ATTACH DATABASE ':memory:' AS other", .notReadOnly)
    await refused(pool, "WITH x AS (SELECT 1) DELETE FROM sessions", .notReadOnly)
    await refused(pool, "WITH x AS (SELECT 1) INSERT INTO other VALUES (1)", .notReadOnly)
    await refused(pool, "SELECT * FROM nope", .unknownRelation("nope"))
    #expect(try await column(pool, "SELECT value FROM json_each('[1,2]')") == ["1", "2"])
  }

  @Test func theRejectedAttemptsLeaveTheConnectionUsable() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, capacity: 1, catalog: Self.hiding)

    await refused(pool, "SELECT count(*) FROM other", .forbidden("other"))
    await #expect(throws: DatabaseError.self) { _ = try await pool.run("SELECT 1; SELECT 2", scope: .shared()) }
    await #expect(throws: DatabaseError.self) { _ = try await pool.run("SELECT json_extract('{', '$')", scope: .shared()) }
    #expect(try await column(pool, "SELECT count(*) FROM sessions") == ["1"])
  }

  @Test func viewerAnswersThePerQueryScope() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, capacity: 1)

    #expect(try await column(pool, "SELECT viewer()", scope: .shared(viewer: "carol")) == ["carol"])
    let (rows, _) = try await pool.run("SELECT viewer()", scope: .shared())
    #expect(rows.rows == [[.null]])
  }

  @Test func aNewTableIsVisibleOnTheNextQuery() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, capacity: 1)
    await refused(pool, "SELECT n FROM \"/t.table\"", .unknownRelation("/t.table"))

    let writer = try DatabaseQueue(path: file.path)
    try await writer.write { db in
      try db.execute(sql: "CREATE TABLE \"/t.table\" (n INTEGER); INSERT INTO \"/t.table\" VALUES (7)")
    }
    #expect(try await column(pool, "SELECT n FROM \"/t.table\"") == ["7"])
  }

  @Test func argumentsBindAndTheByteLimitHolds() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path)

    let (rows, _) = try await pool.run("SELECT ?, ?", arguments: [1.databaseValue, "x".databaseValue], scope: .shared())
    #expect(rows.rows == [[1.databaseValue, "x".databaseValue]])
    await #expect(throws: DatabaseError.self) { _ = try await pool.run("SELECT ?", scope: .shared()) }
    await #expect(throws: ReadError.tooLarge(byteLimit: 10)) {
      _ = try await pool.run("SELECT 'abcdef' UNION ALL SELECT 'ghijkl'", byteLimit: 10, scope: .shared())
    }
  }

  @Test func aCancelledCallerInterruptsItsStatement() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, capacity: 1)
    let endless = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT count(*) FROM c"

    let task = Task { try await pool.run(endless, scope: .shared()) }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try await column(pool, "SELECT count(*) FROM sessions") == ["2"])
  }

  @Test func concurrentReadersShareThePool() async throws {
    let file = try Fixture()
    let pool = ReadPool(path: file.path, catalog: Self.hiding)

    let counts = try await withThrowingTaskGroup(of: [String].self) { group in
      for _ in 0 ..< 32 {
        group.addTask { try await column(pool, "SELECT count(*) FROM sessions") }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(counts == Array(repeating: ["1"], count: 32))
  }
}

private func column(_ pool: ReadPool, _ sql: String, scope: ReadScope = .shared()) async throws -> [String] {
  let (rows, _) = try await pool.run(sql, scope: scope)
  return rows.rows.map { String(describing: $0[0]).trimmingCharacters(in: ["\""]) }
}

private func refused(_ pool: ReadPool, _ sql: String, _ error: ReadError, sourceLocation: SourceLocation = #_sourceLocation) async {
  await #expect(throws: error, sourceLocation: sourceLocation) { _ = try await pool.run(sql, scope: .shared()) }
  await #expect(throws: error, sourceLocation: sourceLocation) { _ = try await pool.tables(sql, scope: .shared()) }
}
