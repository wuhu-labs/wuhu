import Foundation
import GRDB
import GRDBSQLite
import Scratch
import Testing

// The SQLite behavior the scoped read engine stands on, pinned against the
// linked library on every platform CI builds: the authorizer names the view
// a base-table read goes through, a CTE can borrow any name as that accessor,
// TEMP views live on a read-only connection, declared types survive two view
// levels, and a table the authorizer recorded is a region GRDB's observation
// wakes on.
//
// The accessor alone cannot carry the gate: a flattened view whose columns
// go unread leaves only a columnless read of the base table, named and
// qualified as the FROM item was written, with no accessor. So the engine
// attaches the space file under a secret schema name instead.
@Suite struct SQLiteContractTests {
  @Test func aFlattenedColumnlessReadHasNoAccessor() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec("""
    CREATE TEMP VIEW "__vS_1" AS SELECT * FROM main.sessions;
    CREATE TEMP VIEW sessions AS SELECT * FROM temp."__vS_1";
    """)

    let viaViews = try probe.authorizing("SELECT count(*) FROM sessions")
    let direct = try probe.authorizing("SELECT count(*) FROM main.sessions")
    #expect(viaViews.mainReads.contains(.init(table: "sessions", column: "", accessor: nil)))
    #expect(direct.mainReads == [.init(table: "sessions", column: "", accessor: nil)])
  }

  @Test func aColumnlessReadIsNamedAsWrittenNotAsResolved() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)

    let unqualified = try probe.authorizing("SELECT count(*) FROM OTHER")
    #expect(unqualified.unqualifiedReads == [.init(table: "OTHER", column: "", accessor: nil)])
    #expect(unqualified.mainReads.isEmpty)
    let cte = try probe.authorizing("WITH c AS (SELECT 1) SELECT count(*) FROM c")
    #expect(cte.unqualifiedReads == [.init(table: "c", column: "", accessor: nil)])
    let column = try probe.authorizing("SELECT n FROM OTHER")
    #expect(column.mainReads == [.init(table: "other", column: "n", accessor: nil)])
  }

  @Test func aBaseReadThroughAViewNamesThatViewAsItsAccessor() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)

    let calls = try probe.authorizing("SELECT * FROM sessions")
    #expect(Set(calls.mainReads) == [
      .init(table: "sessions", column: "id", accessor: "__vS_1"),
      .init(table: "sessions", column: "flag", accessor: "__vS_1"),
      .init(table: "sessions", column: "j", accessor: "__vS_1"),
    ])
    #expect(calls.tempReads.allSatisfy { ["sessions", "__vS_1"].contains($0.table) })
  }

  @Test func aCountThroughTheViewsStillReportsTheBaseTable() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)

    let calls = try probe.authorizing("SELECT count(*) FROM sessions")
    #expect(Set(calls.mainReads.map(\.table)) == ["sessions"])
    #expect(calls.mainReads.allSatisfy { $0.accessor == "__vS_1" })
  }

  @Test func aCTEBorrowsItsOwnNameAsTheAccessor() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)

    let shadow = try probe.authorizing("WITH sessions AS (SELECT * FROM main.sessions) SELECT * FROM sessions")
    #expect(Set(shadow.mainReads.map(\.accessor)) == ["sessions"])
    let guessed = try probe.authorizing("WITH \"__vS_1\" AS (SELECT * FROM main.sessions) SELECT * FROM \"__vS_1\"")
    #expect(Set(guessed.mainReads.map(\.accessor)) == ["__vS_1"])
  }

  @Test func anAliasedSubqueryHasNoAccessor() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)

    let calls = try probe.authorizing("SELECT * FROM (SELECT * FROM main.sessions) AS \"__vS_1\"")
    #expect(Set(calls.mainReads.map(\.accessor)) == [nil])
  }

  @Test func tempViewsLiveOnAReadOnlyConnectionThatStillCannotWriteMain() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)

    #expect(try probe.column("SELECT count(*) FROM sessions") == ["1"])
    #expect(throws: Probe.Failure.self) { try probe.exec("INSERT INTO main.sessions VALUES ('x', 0, '{}')") }
  }

  @Test func declaredTypesSurviveTwoViewLevels() throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)

    #expect(try probe.decltypes("SELECT * FROM sessions") == ["TEXT", "BOOLEAN", "JSON_TEXT"])
    #expect(try probe.decltypes("SELECT flag, j, 1 AS n FROM sessions") == ["BOOLEAN", "JSON_TEXT", nil])
  }

  @Test func anAuthorizerRecordedTableWakesGRDBRegionObservation() async throws {
    let file = try Fixture()
    let probe = try Probe(path: file.path)
    try probe.exec(Fixture.views)
    let tables = try Set(probe.authorizing("SELECT id FROM sessions").mainReads.map(\.table))
    #expect(tables == ["sessions"])

    let writer = try DatabaseQueue(path: file.path)
    let (wakes, continuation) = AsyncStream<Void>.makeStream()
    let observation = DatabaseRegionObservation(tracking: tables.map { Table($0) })
      .start(in: writer, onError: { _ in continuation.finish() }, onChange: { _ in continuation.yield(()) })
    defer { observation.cancel() }

    try await writer.write { db in try db.execute(sql: "INSERT INTO other VALUES (1)") }
    try await writer.write { db in try db.execute(sql: "UPDATE sessions SET flag = 1 WHERE id = 'hidden'") }
    try await writer.write { db in try db.execute(sql: "INSERT INTO other VALUES (2)") }
    continuation.finish()
    var count = 0
    for await _ in wakes { count += 1 }
    #expect(count == 1)
    #expect(try probe.column("SELECT count(*) FROM main.sessions WHERE flag = 1") == ["2"])
  }
}

// A WAL database the way Space.open leaves one, with a hidden row the views
// filter out.
struct Fixture: ~Copyable {
  static let views = """
  CREATE TEMP VIEW "__vS_1" AS SELECT id, flag, j FROM main.sessions WHERE id <> 'hidden';
  CREATE TEMP VIEW sessions AS SELECT * FROM temp."__vS_1";
  """

  let directory: URL
  var path: String { directory.appending(path: "space.sqlite").path }

  init() throws {
    let url = try scratchURL("spacesql")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var configuration = Configuration()
    configuration.journalMode = .wal
    let queue = try DatabaseQueue(path: url.appending(path: "space.sqlite").path, configuration: configuration)
    try queue.write { db in
      try db.execute(sql: """
      CREATE TABLE sessions (id TEXT PRIMARY KEY, flag BOOLEAN, j JSON_TEXT);
      INSERT INTO sessions VALUES ('a', 1, '{}'), ('hidden', 0, '[]');
      CREATE TABLE other (n INTEGER);
      """)
    }
    directory = url
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }
}

final class Probe {
  struct Failure: Error {
    let message: String
  }

  struct Read: Hashable {
    let table: String
    let column: String
    let accessor: String?
  }

  struct Calls {
    var mainReads: [Read] = []
    var tempReads: [Read] = []
    var unqualifiedReads: [Read] = []
  }

  private let handle: OpaquePointer
  private var calls = Calls()

  init(path: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
      throw Failure(message: "open \(path)")
    }
    self.handle = handle
  }

  deinit {
    sqlite3_close_v2(handle)
  }

  func exec(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  func authorizing(_ sql: String) throws -> Calls {
    calls = Calls()
    sqlite3_set_authorizer(handle, { context, action, first, second, database, accessor in
      let probe = Unmanaged<Probe>.fromOpaque(context!).takeUnretainedValue()
      guard action == SQLITE_READ, let first, let second else { return SQLITE_OK }
      let read = Read(table: String(cString: first), column: String(cString: second), accessor: accessor.map { String(cString: $0) })
      switch database.map({ String(cString: $0) }) {
      case nil: probe.calls.unqualifiedReads.append(read)
      case "main": probe.calls.mainReads.append(read)
      default: probe.calls.tempReads.append(read)
      }
      return SQLITE_OK
    }, Unmanaged.passUnretained(self).toOpaque())
    defer { sqlite3_set_authorizer(handle, nil, nil) }
    try withStatement(sql) { _ in }
    return calls
  }

  func decltypes(_ sql: String) throws -> [String?] {
    try withStatement(sql) { statement in
      (0 ..< sqlite3_column_count(statement)).map { index in
        sqlite3_column_decltype(statement, index).map { String(cString: $0) }
      }
    }
  }

  func column(_ sql: String) throws -> [String] {
    try withStatement(sql) { statement in
      var values: [String] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        values.append(String(cString: sqlite3_column_text(statement, 0)))
      }
      return values
    }
  }

  private func withStatement<R>(_ sql: String, _ body: (OpaquePointer) throws -> R) throws -> R {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw Failure(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }
}
