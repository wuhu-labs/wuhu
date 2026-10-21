import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MigrationTests {
  private func database() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    return try DatabaseQueue(path: "file:/migration-\(UUID())?vfs=memdb", configuration: configuration)
  }

  private func baseline(_ database: DatabaseQueue) async throws -> Space {
    let space = try Space(writer: database)
    _ = try await space.addAccount(kind: .human, name: "Kept")
    let machine = try await space.addMachine(name: "box").id
    let exec = try await space.claimExec(machine: machine, caller: "caller", toolCallID: .init("call"))
    try await database.write { db in
      try db.execute(sql: "DROP TABLE grdb_migrations")
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_spec")
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_end_owed")
      try db.execute(sql: "ALTER TABLE session_api_receipts DROP COLUMN request")
      try db.execute(sql: "CREATE TABLE exec_jobs (exec_id TEXT PRIMARY KEY, spec TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO exec_jobs VALUES (?, '{}')", arguments: [exec.record.id.rawValue])
    }
    return space
  }

  @Test func failedUpgradeRollsBackAndCanBeRetried() async throws {
    let database = try database()
    let original = try await baseline(database)
    try await database.write { db in try db.execute(sql: "ALTER TABLE exec_jobs DROP COLUMN spec") }
    #expect(throws: DatabaseError.self) { try Space(writer: database) }
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 0)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_table_info('machine_execs') WHERE name = 'tool_spec'") } == 0)
    try await database.write { db in
      try db.execute(sql: "ALTER TABLE exec_jobs ADD COLUMN spec TEXT")
      try db.execute(sql: "UPDATE exec_jobs SET spec = '{}'")
    }
    let reopened = try DatabaseQueue(path: database.path)
    let space = try Space(writer: reopened)
    #expect(try await space.accounts().contains { $0.name == "Kept" })
    #expect(try await space.owedExecs().map(\.toolSpec) == ["{}"])
    try await original.close()
    try await space.close()
  }

  @Test func upgradePreservesRowsAndRunsOnlyOnce() async throws {
    let database = try database()
    let original = try await baseline(database)
    let firstConnection = try DatabaseQueue(path: database.path)
    let first = try Space(writer: firstConnection)
    #expect(try await first.accounts().contains { $0.name == "Kept" })
    let owed = try #require(try await first.owedExecs().first)
    #expect(owed.toolSpec == "{}")
    #expect(owed.toolEndOwed)
    let identity = try await first.identity()
    try await database.write { db in
      try db.execute(sql: "CREATE TABLE exec_jobs (exec_id TEXT PRIMARY KEY, spec TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO exec_jobs VALUES (?, 'changed')", arguments: [owed.id.rawValue])
    }
    let secondConnection = try DatabaseQueue(path: database.path)
    let second = try Space(writer: secondConnection)
    #expect(try await second.identity() == identity)
    #expect(try await second.accounts().contains { $0.name == "Kept" })
    #expect(try await second.owedExecs() == [owed])
    try await original.close()
    try await first.close()
    try await second.close()
  }

  @Test func existingForeignKeyViolationsDoNotPreventUpgrade() async throws {
    let database = try database()
    let original = try await baseline(database)
    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('shared', 'missing', '2026-01-01T00:00:00Z')")
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let connection = try DatabaseQueue(path: database.path)
    let upgraded = try Space(writer: connection)
    #expect(try await upgraded.accounts().contains { $0.name == "Kept" })
    #expect(try await upgraded.owedExecs().map(\.toolSpec) == ["{}"])
    try await original.close()
    try await upgraded.close()
  }

  @Test func missingBaselineCompactionIsRefusedWithoutApplyingMigration() async throws {
    let database = try database()
    let original = try await baseline(database)
    try await database.write { db in try db.execute(sql: "DELETE FROM schema_compactions WHERE name = 'wuhu-45'") }
    #expect(throws: SpaceError.needsMigration("wuhu-45")) { try Space(writer: database) }
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 0)
    #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pragma_table_info('machine_execs') WHERE name = 'tool_spec'") } == 0)
    try await original.close()
  }

  @Test func freshBootRecordsLinksCompactionWithItsMigration() async throws {
    let database = try database()
    let space = try Space(writer: database)
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT name FROM schema_compactions ORDER BY name") } == ["wuhu-45", "wuhu-45-links"])
    try await space.close()
  }

  /// What a schema comparison can hold to. The `CREATE TABLE` text cannot:
  /// 001 adds columns to an old table with `ALTER`, which SQLite records in
  /// its own formatting, while a fresh table declares them inline. Columns,
  /// indexes, keys and triggers can — plus the exact text of every index and
  /// trigger, which no migration rewrites.
  private func schemaShape(_ database: DatabaseQueue) throws -> (tables: [String: [String]], indexesAndTriggers: [String]) {
    try database.read { db in
      var shape: [String: [String]] = [:]
      let tables = try String.fetchAll(db, sql: """
      SELECT name FROM sqlite_master WHERE type = 'table'
        AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'wuhu://%' AND name NOT LIKE '%.table'
      ORDER BY name
      """)
      for table in tables {
        var lines = try Row.fetchAll(
          db, sql: #"SELECT cid, name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?) ORDER BY cid"#,
          arguments: [table],
        ).map { "column \($0)" }
        for index in try Row.fetchAll(
          db, sql: #"SELECT name, "unique", origin, partial FROM pragma_index_list(?) ORDER BY name"#, arguments: [table],
        ) {
          let name: String = index["name"]
          let keys = try Row.fetchAll(
            db, sql: #"SELECT seqno, cid, name, "desc", coll, "key" FROM pragma_index_xinfo(?) ORDER BY seqno"#, arguments: [name],
          ).map(\.description)
          lines.append("index \(index) \(keys)")
        }
        lines += try Row.fetchAll(
          db, sql: #"SELECT id, seq, "table", "from", "to", on_update, on_delete, "match" FROM pragma_foreign_key_list(?) ORDER BY id, seq"#,
          arguments: [table],
        ).map { "foreign key \($0)" }
        lines += try String.fetchAll(
          db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name", arguments: [table],
        ).map { "trigger \($0)" }
        shape[table] = lines
      }
      let indexesAndTriggers = try String.fetchAll(db, sql: """
      SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
      WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'wuhu://%'
      ORDER BY 1
      """)
      return (shape, indexesAndTriggers)
    }
  }

  private static let dropped = [
    "claude_code_handovers", "claude_code_sessions", "claude_history_calls", "claude_history_items",
    "claude_history_progress", "claude_history_seen", "contractor_entries", "contractor_rate_limits",
    "contractor_slots", "contractors", "exec_jobs", "physical_sessions", "session_mirror",
    "session_scope_context", "session_watches",
  ]

  /// The tables the removed executors and the pre-groups stores left behind,
  /// with the shape a real old space carries them in.
  private static let legacySchema = """
  CREATE TABLE IF NOT EXISTS "contractors" (
    "name" TEXT NOT NULL PRIMARY KEY,
    "allocation" INTEGER NOT NULL UNIQUE,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "capabilities" TEXT,
    "created_at" TEXT NOT NULL,
    "removed_at" TEXT
  );
  CREATE INDEX IF NOT EXISTS "contractors_by_account" ON "contractors" ("account_id");
  CREATE TABLE IF NOT EXISTS "contractor_slots" (
    "contractor" TEXT NOT NULL PRIMARY KEY REFERENCES "contractors" ("name"),
    "generation" INTEGER NOT NULL,
    "claimed_at" TEXT NOT NULL,
    "last_seen" TEXT NOT NULL,
    "released_at" TEXT,
    "disconnect_notified_at" TEXT
  );
  CREATE TABLE IF NOT EXISTS "contractor_rate_limits" (
    "contractor" TEXT NOT NULL PRIMARY KEY REFERENCES "contractors" ("name"),
    "report" TEXT NOT NULL,
    "reported_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "contractor_entries" (
    "session_id" TEXT NOT NULL,
    "physical_session_id" TEXT NOT NULL,
    "ordinal" INTEGER NOT NULL,
    "kind" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    "received_at" TEXT NOT NULL,
    "emitted_at" TEXT,
    PRIMARY KEY ("session_id", "physical_session_id", "ordinal")
  );
  CREATE TABLE IF NOT EXISTS "claude_code_sessions" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "claude_session_id" TEXT NOT NULL,
    "pending_note" TEXT,
    "environment" TEXT
  );
  CREATE TABLE IF NOT EXISTS "claude_code_handovers" (
    "session_id" TEXT NOT NULL,
    "entry_uuid" TEXT NOT NULL,
    "effect" TEXT NOT NULL,
    "handed_over_at" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "claude_code_handovers_by_entry" ON "claude_code_handovers" ("session_id", "entry_uuid");
  CREATE TABLE IF NOT EXISTS "claude_history_progress" (
    "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "version" INTEGER NOT NULL, "epoch" TEXT NOT NULL,
    "next_line" INTEGER NOT NULL, "offset" INTEGER NOT NULL, "count" INTEGER NOT NULL,
    "raw_head" INTEGER NOT NULL, "handover_head" INTEGER NOT NULL, "summary_position" INTEGER NOT NULL, "ready" INTEGER NOT NULL,
    PRIMARY KEY ("session_id", "generation")
  );
  CREATE TABLE IF NOT EXISTS "claude_history_items" (
    "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "position" INTEGER NOT NULL,
    "payload" TEXT NOT NULL, "origin" INTEGER, "call_id" TEXT,
    PRIMARY KEY ("session_id", "generation", "position")
  );
  CREATE TABLE IF NOT EXISTS "claude_history_seen" (
    "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "uuid" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "generation", "uuid")
  );
  CREATE TABLE IF NOT EXISTS "claude_history_calls" (
    "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "call_id" TEXT NOT NULL,
    "origin" INTEGER NOT NULL, "wuhu" INTEGER NOT NULL,
    PRIMARY KEY ("session_id", "generation", "call_id")
  );
  CREATE TABLE IF NOT EXISTS "exec_jobs" (
    "session_id" TEXT NOT NULL,
    "tool_call_id" TEXT NOT NULL,
    "exec_id" TEXT NOT NULL,
    "notice_id" TEXT NOT NULL,
    "spec" TEXT NOT NULL,
    "started_at" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "tool_call_id")
  );
  CREATE TABLE IF NOT EXISTS "physical_sessions" (
    "session_id" TEXT NOT NULL,
    "id" TEXT NOT NULL,
    "started_at" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "id")
  );
  CREATE TABLE IF NOT EXISTS "session_mirror" (
    "seq" INTEGER NOT NULL PRIMARY KEY,
    "session_id" TEXT NOT NULL,
    "project_key" TEXT NOT NULL,
    "sdk_session_id" TEXT NOT NULL,
    "subpath" TEXT NOT NULL,
    "uuid" TEXT,
    "entry" TEXT NOT NULL,
    "received_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_scope_context" (
    "session_id" TEXT NOT NULL,
    "tool_call_id" TEXT NOT NULL,
    "folders" TEXT NOT NULL,
    "text" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "tool_call_id")
  );
  CREATE TABLE IF NOT EXISTS "session_watches" (
    "session_id" TEXT NOT NULL,
    "identity" TEXT NOT NULL,
    "armed" INTEGER NOT NULL,
    "armed_at" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "identity")
  );
  """

  @Test func anOldSpacesDroppedStoresAndContractorIdentityLeaveTheFreshSchema() async throws {
    let database = try database()
    let original = try await baseline(database)
    let kept = try #require(try await original.accounts().first { $0.name == "Kept" })
    let session = try await original.sessions.createSession(group: .shared, title: "old", kind: .agent, createdBy: "owner", model: .test)
    _ = try await original.sessions.armSubscription(
      session, slot: .init(id: .init("timer.keep"), kind: .timer(.cron("* * * * *"), message: "tick")),
      nextFireAt: Date(timeIntervalSince1970: 1_800_000_000),
    )
    try await database.write { db in
      try db.execute(sql: "INSERT INTO session_subscriptions (session_id, subscription_id, payload, armed_at) VALUES (?, 'park.r-1', '{}', '2026-01-01T00:00:00.000Z')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO accounts (id, kind, name, created_at) VALUES ('ac_0000000a', 'contractor', 'wrapper', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('shared', 'ac_0000000a', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO read_sessions (token_hash, account_id, created_at, expires_at) VALUES ('read-hash', 'ac_0000000a', '2026-01-01T00:00:00.000Z', '2027-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES ('wrapper-key', 'ac_0000000a', 'exec-machine contractor', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES ('kept-key', ?, 'device', '2026-01-01T00:00:00.000Z')", arguments: [kept.id.rawValue])
      try db.execute(sql: "INSERT INTO devices (id, account_id, pubkey, installation, kind, name, created_at, last_seen_at) VALUES ('dev_1', 'ac_0000000a', 'wrapper-key', 'wrapper', 'mac', 'wrapper', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO device_commands (device_id, payload, issued_by, created_at) VALUES ('dev_1', '{}', 'ac_0000000a', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO message_devices (message_id, device_id) VALUES ('m_1', 'dev_1')")
      try db.execute(sql: "INSERT INTO personas (name, allocation, pubkey, account_id, created_at) VALUES ('wrapper', 9001, 'wrapper-key', 'ac_0000000a', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO join_tokens (token_hash, account_id, capabilities, created_at, expires_at, grp) VALUES ('join-hash', 'ac_0000000a', 'device', '2026-01-01T00:00:00.000Z', '2027-01-01T00:00:00.000Z', 'shared')")
      // A row an older binary left dangling: 002 must not validate what it did not write.
      // The baseline's two-column exec_jobs served 001's backfill; the real one goes back in its place.
      try db.execute(sql: "DROP TABLE exec_jobs")
      try db.execute(sql: Self.legacySchema)
      try db.execute(sql: "INSERT INTO contractors (name, allocation, account_id, created_at) VALUES ('wrapper', 9001, 'ac_0000000a', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO contractor_slots (contractor, generation, claimed_at, last_seen) VALUES ('wrapper', 1, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO contractor_rate_limits (contractor, report, reported_at) VALUES ('wrapper', '{}', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO contractor_entries (session_id, physical_session_id, ordinal, kind, payload, received_at) VALUES (?, 'physical', 0, 'entry', '{}', '2026-01-01T00:00:00.000Z')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO claude_code_sessions (session_id, claude_session_id) VALUES (?, 'claude-session')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO claude_code_handovers (session_id, entry_uuid, effect, handed_over_at) VALUES (?, 'entry', 'delivered', '2026-01-01T00:00:00.000Z')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO claude_history_progress (session_id, generation, version, epoch, next_line, offset, count, raw_head, handover_head, summary_position, ready) VALUES (?, 0, 1, 'epoch', 0, 0, 0, 0, 0, 0, 1)", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO claude_history_items (session_id, generation, position, payload) VALUES (?, 0, 0, '{}')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO claude_history_seen (session_id, generation, uuid) VALUES (?, 0, 'entry')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO claude_history_calls (session_id, generation, call_id, origin, wuhu) VALUES (?, 0, 'call', 0, 1)", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO physical_sessions (session_id, id, started_at) VALUES (?, 'physical', '2026-01-01T00:00:00.000Z')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO session_mirror (seq, session_id, project_key, sdk_session_id, subpath, entry, received_at) VALUES (1, ?, 'project', 'sdk', '', '{}', '2026-01-01T00:00:00.000Z')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO session_scope_context (session_id, tool_call_id, folders, text) VALUES (?, 'call', '[]', 'text')", arguments: [session.rawValue])
      try db.execute(sql: "INSERT INTO session_watches (session_id, identity, armed, armed_at) VALUES (?, 'owner', 1, '2026-01-01T00:00:00.000Z')", arguments: [session.rawValue])
    }
    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('shared', 'ac_dangling0', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let reopened = try DatabaseQueue(path: database.path)
    let upgraded = try Space(writer: reopened)
    #expect(try await upgraded.accounts().map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.human, .machine])
    #expect(try await upgraded.accounts().contains { $0.id == kept.id })
    #expect(try await reopened.read { db in try String.fetchAll(db, sql: "SELECT pubkey FROM account_keys") } == ["kept-key"])
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM devices") } == 0)
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM device_commands") } == 0)
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM message_devices") } == 0)
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM personas") } == 0)
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM join_tokens") } == 0)
    #expect(try await reopened.read { db in try String.fetchAll(db, sql: "SELECT subscription_id FROM session_subscriptions ORDER BY 1") } == ["timer.keep"])
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM group_members WHERE account_id = 'ac_0000000a'") } == 0)
    #expect(try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM group_members WHERE account_id = 'ac_dangling0'") } == 1)
    #expect(try await reopened.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name IN (\(Self.dropped.map { "'" + $0 + "'" }.joined(separator: ","))) ORDER BY 1") } == [])
    let fresh = try self.database()
    let freshSpace = try Space(writer: fresh)
    let migrated = try schemaShape(reopened)
    let expected = try schemaShape(fresh)
    #expect(migrated.tables.keys.sorted() == expected.tables.keys.sorted())
    for (table, lines) in expected.tables.sorted(by: { $0.key < $1.key }) {
      #expect(migrated.tables[table] == lines, "\(table)")
    }
    #expect(migrated.indexesAndTriggers == expected.indexesAndTriggers)
    try await original.close()
    try await upgraded.close()
    try await freshSpace.close()
  }

  @Test func newerDatabaseIsRefusedWithoutChanges() async throws {
    let database = try database()
    let original = try Space(writer: database)
    try await database.write { db in try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('003')") }
    #expect(throws: SpaceError.unknownMigrations(["003"])) { try Space(writer: database) }
    #expect(try await database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") } == ["001", "002", "003"])
    try await original.close()
  }
}
