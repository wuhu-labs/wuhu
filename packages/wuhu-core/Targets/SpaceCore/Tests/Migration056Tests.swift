import DeterministicDependencies
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct Migration056Tests {
  /// The manual rollback drops the schema with the ledger row; a rerun that finds the schema still there, its ledger row deleted alone, keeps it as it is.
  @Test(arguments: [false, true]) func itRunsAgainAfterItsLedgerRowIsDeletedWithOrWithoutTheRollback(rolledBack: Bool) async throws {
    let folder = try ScratchFolder("migration-056")
    let file = folder.url.appending(path: "space.sqlite")
    try await Space.open(file: file).close()
    let database = try RawDatabase(path: file.path)
    try database.access { db in
      try db.execute(sql: "INSERT INTO wuwei_successor (id, worker, announced_at) VALUES (1, 'w', 7)")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '056'")
      if rolledBack { try db.execute(sql: "DROP INDEX wuwei_addressable_draining; DROP TABLE wuwei_successor;") }
    }
    let upgraded = try Space.open(file: file)
    try database.access { db throws in
      #expect(try db.strings("SELECT name FROM sqlite_master WHERE name IN ('wuwei_successor', 'wuwei_addressable_draining') ORDER BY name") == ["wuwei_addressable_draining", "wuwei_successor"])
      #expect(try db.int("SELECT count(*) FROM wuwei_successor") == (rolledBack ? 0 : 1))
      #expect(try db.int("SELECT count(*) FROM grdb_migrations WHERE identifier = '056'") == 1)
    }
    try await upgraded.close()
  }
}
