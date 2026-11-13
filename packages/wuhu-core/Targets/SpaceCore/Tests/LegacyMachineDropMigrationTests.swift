import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct LegacyMachineDropMigrationTests {
  @Test func freshSpaceHasNoEncryptedMachineStore() async throws {
    let space = try Space.inMemory()
    #expect(try RawDatabase.open(space.databasePath) { db in
      try LegacyMachineSchema.tables.filter { try db.tableExists($0) }.isEmpty
    })
    #expect(try RawDatabase.open(space.databasePath) { db in
      try ["machine_v2_members", "machine_presence", "machine_descriptions", "machine_operations", "machine_file_operations"].allSatisfy { try db.tableExists($0) }
    })
    try await space.close()
  }

  @Test func upgradeDropsOpaqueLegacyStateAndPreservesCurrentRowsAcrossReopens() async throws {
    let folder = try ScratchFolder("machine-store-drop")
    let file = folder.url.appending(path: "space.sqlite")
    let (before, columns, upgradedShape) = try RawDatabase.open(file.path) { db in
      try Self.create036Fixture(in: db)
      try LegacyMachineSchema.create(in: db)
      try Migration011.apply(db)
      try db.execute(sql: """
      INSERT INTO machine_v2_operations VALUES
        ('opaque', 'shared', 'script', 'read', 'box', 'c1', 'digest', 1, 'opaque-sealed-record', 1, 1024, 'now'),
        ('corrupt', 'shared', 'script', 'write', 'box', 'c2', 'digest', 1, 'not-json-or-ciphertext', 1, 2048, 'now');
      INSERT INTO machine_v2_channels VALUES ('c1', 'opaque', 'data', 'sealed', 'broken', 'broken'), ('c2', 'corrupt', 'data', 'broken', 'broken', 'broken');
      INSERT INTO machine_v2_output VALUES ('o1', 'opaque', 'data', 0, 'sealed'), ('o2', 'corrupt', 'data', 0, 'broken');
      INSERT INTO machine_v2_retention VALUES ('opaque', 'shared', 'read', 'now'), ('corrupt', 'shared', 'write', 'now');
      INSERT INTO machine_v2_maintenance VALUES ('receipts/shared', 'now');
      INSERT INTO machine_v2_key_check VALUES ('key', 'corrupt-key-check');
      """)
      let tables = ["accounts", "machines", "account_keys", "join_tokens", "machine_v2_members", "machine_presence", "machine_descriptions", "machine_operations", "machine_file_operations"]
      let columns = try Dictionary(uniqueKeysWithValues: tables.map { table in
        (table, try db.strings("SELECT name FROM pragma_table_info(?) ORDER BY cid", arguments: [table]))
      })
      let before = try snapshot(db, columns: columns)
      let originalShape = try MigrationTests.schemaShape(db)
      try Migration038.apply(db)
      #expect(try snapshot(db, columns: columns) == before)
      let upgradedShape = try MigrationTests.schemaShape(db)
      #expect(Set(upgradedShape.tables.keys) == Set(tables))
      for table in tables where table != "machine_file_operations" {
        #expect(upgradedShape.tables[table] == originalShape.tables[table])
      }
      let originalFileShape = try #require(originalShape.tables["machine_file_operations"])
      let upgradedFileShape = try #require(upgradedShape.tables["machine_file_operations"])
      let originalFileColumns = originalFileShape.filter { $0.hasPrefix("column ") }
      #expect(Array(upgradedFileShape.prefix(originalFileColumns.count)) == originalFileColumns)
      #expect(upgradedFileShape.filter { !$0.hasPrefix("column ") } == originalFileShape.filter { !$0.hasPrefix("column ") })
      #expect(try LegacyMachineSchema.tables.filter { try db.tableExists($0) }.isEmpty)
      #expect(try db.strings("SELECT name FROM sqlite_master WHERE name IN ('machine_v2_operations_admission', 'machine_v2_channels_by_operation', 'machine_v2_retention_expiry')").isEmpty)
      #expect(try db.strings("SELECT name FROM pragma_table_info('machine_file_operations') ORDER BY cid") == columns["machine_file_operations"]! + ["inputOffsets", "inputEnded", "inputReady", "inputChannels"])
      #expect(try db.int("SELECT count(*) FROM machine_file_operations WHERE inputReady = 0 AND inputOffsets = '{}' AND inputEnded = '[]' AND inputChannels = '[]' AND received = '{\"data\":7}'") == 1)
      #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
      #expect(try db.strings("PRAGMA integrity_check") == ["ok"])
      return (before, columns, upgradedShape)
    }
    try RawDatabase.open(file.path) { db in
      #expect(try snapshot(db, columns: columns) == before)
      let reopenedShape = try MigrationTests.schemaShape(db)
      #expect(reopenedShape.tables == upgradedShape.tables)
      #expect(reopenedShape.indexesAndTriggers == upgradedShape.indexesAndTriggers)
      #expect(try db.int("SELECT count(*) FROM machine_file_operations WHERE inputReady = 0 AND inputOffsets = '{}' AND inputEnded = '[]' AND inputChannels = '[]'")
        == 1)
    }
  }

  private static func create036Fixture(in db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE TABLE accounts (id TEXT NOT NULL PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('human', 'space', 'machine', 'contractor')), name TEXT, created_at TEXT NOT NULL, removed_at TEXT, guest INTEGER NOT NULL DEFAULT 0 CHECK (guest IN (0, 1)));
    CREATE TABLE machines (id TEXT NOT NULL PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), name TEXT, created_at TEXT NOT NULL, grp TEXT NOT NULL DEFAULT '', scope TEXT NOT NULL DEFAULT 'owner' CHECK (scope IN ('owner', 'reachable')));
    CREATE UNIQUE INDEX machines_by_account ON machines(account_id);
    CREATE TRIGGER machines_grp_required BEFORE INSERT ON machines WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: machines'); END;
    CREATE TABLE account_keys (pubkey TEXT NOT NULL PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), capabilities TEXT NOT NULL, created_by TEXT REFERENCES accounts(id), created_at TEXT NOT NULL, expires_at TEXT);
    CREATE INDEX account_keys_by_account ON account_keys(account_id);
    CREATE TABLE join_tokens (token_hash TEXT NOT NULL PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), capabilities TEXT NOT NULL, created_by TEXT REFERENCES accounts(id), created_at TEXT NOT NULL, expires_at TEXT NOT NULL, grp TEXT NOT NULL DEFAULT '');
    CREATE INDEX join_tokens_by_account ON join_tokens(account_id);
    CREATE TRIGGER join_tokens_grp_required BEFORE INSERT ON join_tokens WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: join_tokens'); END;
    CREATE TABLE machine_v2_members (machine_id TEXT PRIMARY KEY REFERENCES machines(id), grp TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE machine_presence (owner TEXT NOT NULL DEFAULT (cell()), state TEXT NOT NULL, observed INTEGER NOT NULL, lease INTEGER, describeAt INTEGER, describeDeadline INTEGER, describeRetry INTEGER NOT NULL, leaseMs INTEGER NOT NULL DEFAULT 60000, pollHoldMs INTEGER, pollBytes INTEGER, resultBytes INTEGER, execStdoutWindow INTEGER, execStderrWindow INTEGER, UNIQUE(owner));
    CREATE TABLE machine_descriptions (owner TEXT NOT NULL DEFAULT (cell()), description TEXT NOT NULL, UNIQUE(owner));
    CREATE TABLE machine_file_operations (owner TEXT NOT NULL DEFAULT (cell()), id TEXT PRIMARY KEY, request TEXT NOT NULL, state TEXT NOT NULL, worker TEXT, stream INTEGER, created INTEGER NOT NULL, dispatched INTEGER NOT NULL, delivered INTEGER NOT NULL, stop TEXT, offsets TEXT NOT NULL, offered TEXT NOT NULL, received TEXT NOT NULL, snapshot TEXT, failure TEXT, endedChannels TEXT NOT NULL, terminalAcks TEXT NOT NULL, flights TEXT NOT NULL);
    CREATE TABLE machine_operations (owner TEXT NOT NULL DEFAULT (cell()), id TEXT PRIMARY KEY, operation TEXT NOT NULL, caller TEXT, toolCall TEXT, script TEXT, stream TEXT, request TEXT NOT NULL, recipient TEXT, state TEXT NOT NULL, opened INTEGER NOT NULL, dispatched INTEGER NOT NULL, background INTEGER NOT NULL, delivered INTEGER NOT NULL, created INTEGER NOT NULL, stdout INTEGER NOT NULL, stderr INTEGER NOT NULL, stdin INTEGER NOT NULL, stdinEnded INTEGER NOT NULL, cursor INTEGER NOT NULL, consumed INTEGER NOT NULL, tail BLOB NOT NULL, cut INTEGER, snapshot TEXT, diagnostic TEXT, stop TEXT, stopSent INTEGER NOT NULL, stopAt INTEGER, answerAt INTEGER, endedChannels TEXT NOT NULL, terminalAcks TEXT NOT NULL, flights TEXT NOT NULL);
    INSERT INTO accounts (id, kind, name, created_at) VALUES ('human', 'human', 'Kept', 'now'), ('box-account', 'machine', 'kept-box', 'now');
    INSERT INTO machines VALUES ('box', 'box-account', 'kept-box', 'now', 'shared', 'reachable');
    INSERT INTO account_keys VALUES ('kept-key', 'box-account', 'machine', 'human', 'now', NULL);
    INSERT INTO join_tokens VALUES ('kept-token', 'box-account', 'machine', 'human', 'now', 'later', 'shared');
    INSERT INTO machine_v2_members VALUES ('box', 'shared', 'now');
    INSERT INTO machine_presence (owner, state, observed, lease, describeRetry) VALUES ('box', 'online', 100, 200, 0);
    INSERT INTO machine_descriptions VALUES ('box', '{"kept":"description"}');
    INSERT INTO machine_operations (owner, id, operation, request, state, opened, dispatched, background, delivered, created, stdout, stderr, stdin, stdinEnded, cursor, consumed, tail, stopSent, endedChannels, terminalAcks, flights)
      VALUES ('box', 'kept-exec', 'operation', '{"kept":"request"}', 'reserved', 0, 0, 0, 0, 1, 7, 3, 2, 0, 1, 1, X'010203', 0, '[]', '[]', '{}');
    INSERT INTO machine_file_operations (owner, id, request, state, worker, stream, created, dispatched, delivered, offsets, offered, received, endedChannels, terminalAcks, flights)
      VALUES ('box', 'kept-file', '{"kept":"request"}', 'streaming', 'worker', 4, 1, 1, 0, '{"data":5}', '{"data":9}', '{"data":7}', '["metadata"]', '["metadata"]', '{}');
    """)
  }

  private func snapshot(_ db: MigrationDB, columns: [String: [String]]) throws -> [String: [String]] {
    try Dictionary(uniqueKeysWithValues: columns.map { table, names in
      let selection = names.map { "\"\($0)\"" }.joined(separator: ",")
      return (table, try db.rows("SELECT \(selection) FROM \"\(table)\" ORDER BY \(selection)").map { String(describing: $0.values) })
    })
  }
}

enum LegacyMachineSchema {
  static let tables = ["machine_v2_operations", "machine_v2_channels", "machine_v2_output", "machine_v2_retention", "machine_v2_maintenance", "machine_v2_key_check"]

  static func create(in db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE TABLE machine_v2_operations (id TEXT PRIMARY KEY, grp TEXT NOT NULL, owner_scope TEXT NOT NULL, invocation_key TEXT NOT NULL, machine_id TEXT NOT NULL, correlation_id TEXT NOT NULL, input_digest TEXT NOT NULL, dispatch_consumed INTEGER NOT NULL, record TEXT NOT NULL, active INTEGER NOT NULL, reserved_bytes INTEGER NOT NULL, created_at TEXT NOT NULL, UNIQUE(grp, owner_scope, invocation_key));
    CREATE TABLE machine_v2_channels (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES machine_v2_operations(id) ON DELETE CASCADE, name TEXT NOT NULL, committed TEXT NOT NULL, accepted TEXT NOT NULL, pending TEXT);
    CREATE TABLE machine_v2_output (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES machine_v2_operations(id) ON DELETE CASCADE, channel TEXT NOT NULL, sequence INTEGER NOT NULL, payload TEXT NOT NULL);
    CREATE TABLE machine_v2_retention (id TEXT PRIMARY KEY, grp TEXT NOT NULL, kind TEXT NOT NULL, expired_at TEXT NOT NULL);
    CREATE INDEX machine_v2_retention_expiry ON machine_v2_retention(grp, kind, expired_at);
    CREATE TABLE machine_v2_maintenance (id TEXT PRIMARY KEY, ran_at TEXT NOT NULL);
    CREATE TABLE machine_v2_key_check (id TEXT PRIMARY KEY, sealed TEXT NOT NULL);
    """)
  }
}
