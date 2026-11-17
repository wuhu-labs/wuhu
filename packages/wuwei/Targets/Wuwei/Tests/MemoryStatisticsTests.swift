import GRDBSQLite
import Testing
import Wuwei

@Test func sqliteKeepsNoMemoryStatistics() throws {
  let writer = try SQLiteWriter(path: ":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
  let code = try writer.access { sqlite3_exec($0, "CREATE TABLE t (x); INSERT INTO t VALUES (randomblob(100000))", nil, nil, nil) }
  #expect(code == SQLITE_OK)
  #expect(sqlite3_memory_used() == 0)
}
