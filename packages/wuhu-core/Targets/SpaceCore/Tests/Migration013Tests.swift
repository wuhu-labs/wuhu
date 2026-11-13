import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import SpaceFS
import Testing

@Suite(.deterministicDependencies) struct MachineTraceMigrationTests {
  private static let retired = ["machine_v2_trace", "machine_v2_incidents", "machine_v2_problem_index"]

  @Test func freshSpaceHasNoTraceOrProblemTables() async throws {
    let space = try Space.inMemory()
    #expect(try RawDatabase.open(space.databasePath) { db in try Self.retired.filter { try db.tableExists($0) } } == [])
    try await space.close()
  }

  @Test func historicalUpgradeDropsTracesAndProblemsAndKeepsReceiptsAndContent() async throws {
    let folder = try ScratchFolder("migration-013")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let database = try RawDatabase(path: file.path)
    let problems = try SpacePath(validating: "/wuhu/machine-v2-problems.table")
    _ = try await original.createTable(problems, header: TableHeader(columns: [.init(name: "status", type: .text)]), in: .shared, acting: .shared)
    _ = try await original.mutateRows(problems, [.insert([.string("keep")])], in: .shared, acting: .shared)
    try database.access { db in
      try LegacyMachineSchema.create(in: db)
      try db.execute(sql: """
      CREATE TABLE machine_v2_trace (id TEXT PRIMARY KEY, grp TEXT NOT NULL, request_id TEXT NOT NULL, correlation_id TEXT NOT NULL, path TEXT NOT NULL, event TEXT NOT NULL, start_at TEXT NOT NULL, elapsed_ms INTEGER NOT NULL, status INTEGER, head_ms INTEGER, error_code TEXT, problem_id INTEGER);
      CREATE INDEX machine_v2_trace_correlation ON machine_v2_trace(grp, correlation_id, start_at);
      CREATE INDEX machine_v2_trace_retention ON machine_v2_trace(grp, start_at);
      CREATE TABLE machine_v2_problem_index (id TEXT PRIMARY KEY, grp TEXT NOT NULL, fingerprint TEXT NOT NULL, row_id INTEGER NOT NULL);
      CREATE TABLE machine_v2_incidents (id TEXT PRIMARY KEY, grp TEXT NOT NULL, trace_group TEXT NOT NULL, fingerprint TEXT NOT NULL, correlation_id TEXT, problem_id INTEGER);
      INSERT INTO machine_v2_trace VALUES ('r', 'shared', 'r', 'c', '/machine/v2/machines/m', 'complete', 'now', 1, 200, 1, NULL, 1);
      INSERT INTO machine_v2_problem_index VALUES ('shared/f', 'shared', 'f', 1);
      INSERT INTO machine_v2_incidents VALUES ('i', 'shared', 'shared', 'f', 'c', 1);
      INSERT INTO machine_v2_retention VALUES ('i', 'shared', 'incident', 'now'), ('o', 'shared', 'operation', 'now');
      INSERT INTO machine_v2_maintenance VALUES ('problems/shared', 'now'), ('receipts/shared', 'now');
      """)
    }
    try database.access { db in try Migration013.apply(db) }
    #expect(try database.access { db in try Self.retired.filter { try db.tableExists($0) } } == [])
    #expect(try database.access { try $0.strings("SELECT name FROM sqlite_master WHERE name LIKE 'machine_v2_trace%'") } == [])
    #expect(try database.access { try $0.strings("SELECT kind FROM machine_v2_retention") } == ["operation"])
    #expect(try database.access { try $0.strings("SELECT id FROM machine_v2_maintenance") } == ["receipts/shared"])
    #expect(try await original.query("SELECT status FROM \"/wuhu/machine-v2-problems.table\"", as: .init(actor: .publicReader, group: .shared)).rows == [[.text("keep")]])
    try await original.close()
  }
}
