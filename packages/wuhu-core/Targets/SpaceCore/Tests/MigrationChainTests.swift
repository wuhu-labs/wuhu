import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MigrationChainTests {
  private func migrate(
    _ db: MigrationDB, chains: [MigrationChain], log: Logger = Logger(label: "test.migration") { _ in SwiftLogNoOpLogHandler() },
  ) throws {
    try MigrationRunner(db: db, log: log, date: .constant(Date(timeIntervalSince1970: 0)), baseline: Migrations.baseline, chains: chains).migrate()
  }

  /// A fresh database and one whose ledger already holds 001–056 end at the same schema and the same ledger.
  @Test func aChainLeavesAFreshDatabaseAndOneAtTheBaselineAtTheSameSchema() throws {
    let folder = try ScratchFolder("migration-chain")
    let fresh = try RawDatabase(path: folder.url.appending(path: "fresh.sqlite").path)
    let atBaseline = try RawDatabase(path: folder.url.appending(path: "baseline.sqlite").path)
    // Registered out of family order on purpose: chains run in `MigrationFamily` order, not registration order.
    let chains = [
      MigrationChain(.agents, migrations: [
        { db in try db.execute(sql: "INSERT INTO probe (id) VALUES ('2')") },
      ]),
      MigrationChain(.group, migrations: [
        { db in try db.execute(sql: "CREATE TABLE probe (id TEXT NOT NULL PRIMARY KEY)") },
        { db in try db.execute(sql: "INSERT INTO probe (id) SELECT CAST(count(*) AS TEXT) FROM accounts") },
      ]),
    ]
    try fresh.access { db in try migrate(db, chains: chains) }
    try atBaseline.access { db in
      try migrate(db, chains: [])
      try migrate(db, chains: chains)
      // Everything is applied now: a third pass runs no migration and inserts nothing twice.
      try migrate(db, chains: chains)
    }
    let freshShape = try fresh.access(MigrationTests.schemaShape)
    let baselineShape = try atBaseline.access(MigrationTests.schemaShape)
    #expect(freshShape.tables.keys.sorted() == baselineShape.tables.keys.sorted())
    for (table, lines) in freshShape.tables {
      #expect(baselineShape.tables[table] == lines, "\(table)")
    }
    #expect(freshShape.indexesAndTriggers == baselineShape.indexesAndTriggers)
    let ledger = Migrations.baseline.map(\.id) + ["group/0001", "group/0002", "agents/0001"]
    for database in [fresh, atBaseline] {
      #expect(try database.access { try $0.strings("SELECT identifier FROM grdb_migrations ORDER BY rowid") } == ledger)
      // `group/0002` read the baseline's `accounts`; `agents` ran after `group`.
      #expect(try database.access { try $0.strings("SELECT id FROM probe ORDER BY id") } == ["0", "2"])
    }
  }

  /// A space at the frozen baseline opens as it is: nothing re-runs, and its schema is a fresh space's.
  @Test func aSpaceAtTheBaselineEndsAtTheSameSchemaAsAFreshOne() async throws {
    let folder = try ScratchFolder("migration-chain")
    let freshLocation = folder.url.appending(path: "fresh.sqlite")
    let baselineLocation = folder.url.appending(path: "baseline.sqlite")
    let fresh = try Space.open(file: freshLocation)
    try await fresh.close()
    let baseline = try RawDatabase(path: baselineLocation.path)
    try baseline.access { db in try migrate(db, chains: []) }
    let upgraded = try Space.open(file: baselineLocation)
    try await upgraded.close()
    let freshShape = try RawDatabase.open(freshLocation.path, readOnly: true, MigrationTests.schemaShape)
    let upgradedShape = try RawDatabase.open(baselineLocation.path, readOnly: true, MigrationTests.schemaShape)
    #expect(freshShape.tables.keys.sorted() == upgradedShape.tables.keys.sorted())
    for (table, lines) in freshShape.tables {
      #expect(upgradedShape.tables[table] == lines, "\(table)")
    }
    #expect(freshShape.indexesAndTriggers == upgradedShape.indexesAndTriggers)
    #expect(try RawDatabase.open(baselineLocation.path, readOnly: true) { try $0.strings("SELECT identifier FROM grdb_migrations ORDER BY rowid") } == Migrations.baseline.map(\.id) + ["conversations/0001"])
  }

  @Test func anUnknownLedgerIdentifierIsRefusedBeforeAnythingRuns() throws {
    let folder = try ScratchFolder("migration-chain")
    let database = try RawDatabase(path: folder.url.appending(path: "space.sqlite").path)
    let chains = [
      MigrationChain(.group, migrations: [
        { db in try db.execute(sql: "CREATE TABLE probe (id TEXT NOT NULL)") },
      ]),
    ]
    try database.access { db in
      try migrate(db, chains: [])
      try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('998'), ('group/0002')")
    }
    #expect(throws: SpaceError.unknownMigrations(["998", "group/0002"])) { try database.access { db in try migrate(db, chains: chains) } }
    #expect(try database.access { try $0.strings("SELECT name FROM sqlite_master WHERE name = 'probe'") } == [])
  }

  /// A migration added after the baseline is recorded by its family and its position in the chain, once.
  @Test func aChainMigrationIsRecordedByItsFamilyAndPosition() throws {
    let folder = try ScratchFolder("migration-chain")
    let database = try RawDatabase(path: folder.url.appending(path: "space.sqlite").path)
    let logs = RecordedLogs()
    let chains = [
      MigrationChain(.group, migrations: [
        { db in try db.execute(sql: "CREATE TABLE probe (position INTEGER NOT NULL)") },
        { db in try db.execute(sql: "INSERT INTO probe (position) VALUES (1)") },
        { db in try db.execute(sql: "INSERT INTO probe (position) VALUES (2)") },
      ]),
    ]
    try database.access { db in
      try migrate(db, chains: chains, log: logs.logger)
      try migrate(db, chains: chains, log: logs.logger)
    }
    #expect(try database.access { try $0.strings("SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 3") } == ["group/0003", "group/0002", "group/0001"])
    #expect(try database.access { try $0.int("SELECT count(*) FROM probe") } == 2)
    #expect(logs.all.map(\.message).filter { $0.hasPrefix("migration group/") } == ["0001", "0002", "0003"].flatMap { ["migration group/\($0): applying", "migration group/\($0): applied in 0 ms"] })
  }
}
