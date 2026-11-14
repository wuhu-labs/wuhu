import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import enum SpaceSQL.PageCache
import Testing

@Suite(.deterministicDependencies) struct MigrationTests {
  private func baseline(_ location: URL) async throws -> Space {
    let space = try Space.open(file: location)
    try RawDatabase.open(location.path) { db in
      try db.execute(sql: "INSERT INTO accounts (id, kind, name, created_at) VALUES ('ac_kept00001', 'human', 'Kept', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('001', '002', '005', '042')")
      try db.execute(sql: """
      CREATE TABLE machine_execs (
        id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, stream_id INTEGER NOT NULL,
        command TEXT NOT NULL, caller TEXT, tool_call_id TEXT, started_at TEXT NOT NULL,
        terminal_state TEXT, kill_delivered INTEGER NOT NULL DEFAULT 0, grp TEXT NOT NULL
      );
      INSERT INTO machine_execs VALUES ('ex_old', 'old-box', 1, '', 'caller', 'call', '2026-01-01T00:00:00Z', NULL, 0, 'shared');
      """)
      try db.execute(sql: """
      CREATE TABLE session_api_receipts (
        session_id TEXT NOT NULL, tool_call_id TEXT NOT NULL, status INTEGER NOT NULL,
        body TEXT NOT NULL, recorded_at TEXT NOT NULL, PRIMARY KEY (session_id, tool_call_id)
      );
      """)
      try db.execute(sql: "CREATE TABLE exec_jobs (exec_id TEXT PRIMARY KEY, spec TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO exec_jobs VALUES (?, '{}')", arguments: ["ex_old"])
    }
    return space
  }

  @Test func failedUpgradeRollsBackAndCanBeRetried() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try await baseline(location)
    try database.access { db in try db.execute(sql: "ALTER TABLE exec_jobs DROP COLUMN spec") }
    let logs = RecordedLogs()
    #expect(throws: MigrationFailure.self) { try Space.open(file: location, log: logs.logger) }
    #expect(logs.all.last { $0.message.hasPrefix("migration ") }?.message.hasSuffix(": applying") == true)
    #expect(try database.access { try $0.int("SELECT count(*) FROM grdb_migrations WHERE identifier IN ('001', '002', '005')") } == 0)
    #expect(try database.access { try $0.int("SELECT count(*) FROM pragma_table_info('machine_execs') WHERE name = 'tool_spec'") } == 0)
    try database.access { db in
      try db.execute(sql: "ALTER TABLE exec_jobs ADD COLUMN spec TEXT")
      try db.execute(sql: "UPDATE exec_jobs SET spec = '{}'")
    }
    let space = try Space.open(file: location)
    #expect(try await space.accounts().contains { $0.name == "Kept" })
    #expect(try await space.owedExecs().map(\.toolSpec) == ["{}"])
    try await original.close()
    try await space.close()
  }

  @Test func upgradePreservesRowsAndRunsOnlyOnce() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try await baseline(location)
    let shared = await original.fs(.shared)
    let settings = await original.fs(.settings)
    let file = try SpacePath(validating: "/kept.md")
    let attribution = RevisionAttribution(actor: "reader", via: "page:/kept.html")
    _ = try await original.writeFile(file, data: Data("one".utf8), in: .shared, acting: .settings, attribution: attribution, ifMatch: nil, createOnly: false)
    _ = try await shared.write(file.rawValue, Data("two".utf8), ifMatch: nil)
    _ = try await settings.write(file.rawValue, Data("foreign".utf8), ifMatch: nil)
    let table = try SpacePath(validating: "/kept.table")
    _ = try await original.createTable(table, header: TableHeader(columns: []), in: .shared, acting: .settings)
    let inserted = try await original.commitRows(table, [.insert([])], in: .shared, acting: .settings)
    let history = try await original.history(file, in: .shared)
    let historical = database
    try await original.close()
    try historical.access { db in
      try db.execute(sql: """
      UPDATE fs_versions SET rev = 9 WHERE grp = 'settings';
      UPDATE fs_heads SET rev = 9 WHERE grp = 'settings';
      DROP TABLE revisions;
      DROP TABLE revision_actors;
      CREATE TABLE revisions (rev INTEGER PRIMARY KEY AUTOINCREMENT, mtime TEXT NOT NULL, grp TEXT NOT NULL);
      CREATE TABLE revision_actors (rev INTEGER PRIMARY KEY, actor TEXT, via TEXT NOT NULL);
      INSERT INTO revisions VALUES (1, '2026-01-01T00:00:00Z', 'settings'), (2, '2026-01-02T00:00:00Z', 'shared'), (3, '2026-01-03T00:00:00Z', 'settings'), (4, '2026-01-04T00:00:00Z', 'settings'), (9, '2026-01-09T00:00:00Z', 'shared'), (12, '2026-01-12T00:00:00Z', 'shared');
      INSERT INTO revision_actors VALUES (1, 'reader', 'page:/kept.html'), (9, 'reader', 'page:/foreign.html');
      DROP TABLE session_prompts;
      CREATE TABLE session_prompts (session_id TEXT PRIMARY KEY, generation INTEGER NOT NULL, rev INTEGER NOT NULL, rendered TEXT, session TEXT, CHECK ((rendered IS NULL) = (session IS NULL)));
      INSERT INTO session_prompts VALUES ('kept-session', 0, 9, NULL, NULL);
      DELETE FROM grdb_migrations WHERE identifier = '046';
      """)
    }
    let first = try Space.open(file: location)
    #expect(try await first.accounts().contains { $0.name == "Kept" })
    #expect(try await first.currentRevision(in: .shared) == 12)
    #expect(try await first.currentRevision(in: .settings) == 12)
    #expect(try await first.fs(.shared, at: Rev(8)).read(file.rawValue).1 == Data("two".utf8))
    #expect(try await first.fs(.settings, at: Rev(9)).read(file.rawValue).1 == Data("foreign".utf8))
    let migratedHistory = try await first.history(file, in: .shared)
    #expect(migratedHistory.map(\.0) == history.map(\.0))
    #expect(migratedHistory.map { SQLiteDateFormat.string(from: $0.1) } == ["2026-01-01T00:00:00.000Z", "2026-01-02T00:00:00.000Z"])
    #expect(try await first.tableSchema(table, in: .shared, rev: Rev(8)).token.rev == inserted.rev.value)
    #expect(try await first.query("SELECT id FROM \"/kept.table\"").rows.count == 1)
    let actors = try await first.attributions(of: [(.shared, Rev(1)), (.settings, Rev(9))])
    #expect(actors[.shared]?[Rev(1)] == attribution)
    #expect(actors[.settings]?[Rev(9)]?.via == "page:/foreign.html")
    #expect(try historical.access { try $0.string("SELECT revs FROM session_prompts WHERE session_id = 'kept-session'") }.map { try JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) } == ["shared": 9, "settings": 9])
    #expect(try await first.fs(.shared).write(file.rawValue, Data("three".utf8), ifMatch: nil).rev == 13)
    #expect(try await first.currentRevision(in: .settings) == 12)
    let owed = try #require(try await first.owedExecs().first)
    #expect(owed.toolSpec == "{}")
    let identity = try await first.identity()
    await first.stopWorker()
    try historical.access { db in
      try db.execute(sql: "CREATE TABLE exec_jobs (exec_id TEXT PRIMARY KEY, spec TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO exec_jobs VALUES (?, 'changed')", arguments: [owed.id])
    }
    let second = try Space.open(file: location)
    #expect(try await second.identity() == identity)
    #expect(try await second.accounts().contains { $0.name == "Kept" })
    #expect(try await second.owedExecs() == [owed])
    try await first.close()
    try await second.close()
  }

  @Test func existingForeignKeyViolationsDoNotPreventUpgrade() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try await baseline(location)
    try database.access { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(
        sql: "INSERT INTO read_sessions (token_hash, account_id, created_at, expires_at) VALUES ('stale', 'missing', '2026-01-01T00:00:00Z', '2027-01-01T00:00:00Z')",
      )
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let upgraded = try Space.open(file: location)
    #expect(try await upgraded.accounts().contains { $0.name == "Kept" })
    #expect(try await upgraded.owedExecs().map(\.toolSpec) == ["{}"])
    try await original.close()
    try await upgraded.close()
  }

  @Test func missingBaselineCompactionIsRefusedWithoutApplyingMigration() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try await baseline(location)
    try database.access { db in try db.execute(sql: "DELETE FROM schema_compactions WHERE name = 'wuhu-45'") }
    #expect(throws: SpaceError.needsMigration("wuhu-45")) { try Space.open(file: location) }
    #expect(try database.access { try $0.int("SELECT count(*) FROM grdb_migrations WHERE identifier IN ('001', '002', '005')") } == 0)
    #expect(try database.access { try $0.int("SELECT count(*) FROM pragma_table_info('machine_execs') WHERE name = 'tool_spec'") } == 0)
    try await original.close()
  }

  @Test func historicalMachineCellMigrationDropsExecStateButKeepsFileOperations() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try Space.open(file: location)
    try database.access { db in
      try db.execute(sql: "INSERT INTO accounts (id, kind, name, created_at) VALUES ('ac_kept00001', 'human', 'Kept', '2026-01-01T00:00:00.000Z')")
      try LegacyMachineSchema.create(in: db)
      try db.execute(sql: """
      DROP TABLE machine_operations;
      DROP TABLE machine_presence;
      CREATE TABLE machine_execs (
        id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, stream_id INTEGER NOT NULL,
        command TEXT NOT NULL, caller TEXT, tool_call_id TEXT, started_at TEXT NOT NULL,
        terminal_state TEXT, kill_delivered INTEGER NOT NULL DEFAULT 0, grp TEXT NOT NULL,
        tool_spec TEXT, tool_end_owed INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE script_execs (exec_id TEXT PRIMARY KEY, script_id TEXT NOT NULL, session_id TEXT NOT NULL, grp TEXT NOT NULL);
      CREATE TABLE machine_v2_presence (machine_id TEXT PRIMARY KEY, grp TEXT NOT NULL, state TEXT NOT NULL, description TEXT, observed_at TEXT NOT NULL, reason TEXT);
      INSERT INTO machine_execs VALUES ('ex_old', 'box', 1, 'sleep', 'caller', 'call', '2026-01-01T00:00:00Z', NULL, 0, 'shared', '{}', 1);
      INSERT INTO script_execs VALUES ('ex_old', 'script', 'caller', 'shared');
      INSERT INTO machine_v2_presence VALUES ('box', 'shared', 'attached', '{}', '2026-01-01T00:00:00Z', NULL);
      INSERT INTO machine_v2_operations VALUES
        ('exec-op', 'shared', 'exec/ex_old', 'exec', 'box', 'exec-correlation', 'digest', 1, '{}', 1, 1024, '2026-01-01T00:00:00Z'),
        ('file-op', 'shared', 'script', 'read', 'box', 'file-correlation', 'digest', 1, '{}', 1, 1024, '2026-01-01T00:00:00Z');
      INSERT INTO machine_v2_channels VALUES ('exec-channel', 'exec-op', 'stdout', '0', '0', NULL), ('file-channel', 'file-op', 'data', '0', '0', NULL);
      INSERT INTO machine_v2_output VALUES ('exec-output', 'exec-op', 'stdout', 0, 'exec bytes'), ('file-output', 'file-op', 'data', 0, 'file bytes');
      INSERT INTO machine_v2_retention VALUES ('exec-op', 'shared', 'exec', '2026-01-01T00:00:00Z'), ('file-op', 'shared', 'read', '2026-01-01T00:00:00Z');
      """)
    }
    try database.access { try Migration033.apply($0) }
    #expect(try await original.accounts().contains { $0.name == "Kept" })
    #expect(try database.access { try $0.strings("SELECT name FROM sqlite_master WHERE name IN ('machine_execs', 'script_execs', 'machine_v2_presence')") } == [])
    #expect(try database.access { try $0.int("SELECT count(*) FROM machine_operations") } == 0)
    #expect(try database.access { try $0.int("SELECT count(*) FROM machine_presence") } == 0)
    #expect(try database.access { try $0.strings("SELECT id FROM machine_v2_operations") } == ["file-op"])
    #expect(try database.access { try $0.strings("SELECT id FROM machine_v2_channels") } == ["file-channel"])
    #expect(try database.access { try $0.strings("SELECT id FROM machine_v2_output") } == ["file-output"])
    #expect(try database.access { try $0.strings("SELECT id FROM machine_v2_retention") } == ["file-op"])
    try await original.close()
  }

  @Test func freshBootRecordsLinksCompactionWithItsMigration() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let space = try Space.open(file: location)
    #expect(try database.access { try $0.strings("SELECT name FROM schema_compactions ORDER BY name") } == ["wuhu-45", "wuhu-45-links"])
    try await space.close()
  }

  /// What a schema comparison can hold to. The `CREATE TABLE` text cannot:
  /// 001 adds columns to an old table with `ALTER`, which SQLite records in
  /// its own formatting, while a fresh table declares them inline. Columns,
  /// indexes, keys and triggers can — plus the exact text of every index and
  /// trigger, which no migration rewrites.
  static func schemaShape(_ db: MigrationDB) throws -> (tables: [String: [String]], indexesAndTriggers: [String]) {
    var shape: [String: [String]] = [:]
    let tables = try db.strings("""
    SELECT name FROM sqlite_master WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'wuhu://%' AND name NOT LIKE '%.table'
    ORDER BY name
    """)
    for table in tables {
      var lines = try db.rows(
        #"SELECT cid, name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?) ORDER BY cid"#,
        arguments: [table],
      ).map { "column \($0.values)" }
      for index in try db.rows(
        #"SELECT name, "unique", origin, partial FROM pragma_index_list(?) ORDER BY name"#,
        arguments: [table],
      ) {
        let name: String = index["name"]
        let keys = try db.rows(
          #"SELECT seqno, cid, name, "desc", coll, "key" FROM pragma_index_xinfo(?) ORDER BY seqno"#,
          arguments: [name],
        ).map { String(describing: $0.values) }
        lines.append("index \(index.values) \(keys)")
      }
      lines += try db.rows(
        #"SELECT id, seq, "table", "from", "to", on_update, on_delete, "match" FROM pragma_foreign_key_list(?) ORDER BY id, seq"#,
        arguments: [table],
      ).map { "foreign key \($0.values)" }
      lines += try db.strings(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name",
        arguments: [table],
      ).map { "trigger \($0)" }
      shape[table] = lines
    }
    let indexesAndTriggers = try db.strings("""
    SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
    WHERE type IN ('index', 'trigger') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'wuhu://%'
    ORDER BY 1
    """)
    return (shape, indexesAndTriggers)
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
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    // A space at migration 001, carrying the stores a real old space still had.
    try database.access { db in
      try Migration001.apply(db)
      try db.execute(sql: """
      CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
      INSERT INTO grdb_migrations VALUES ('001');
      INSERT INTO accounts (id, kind, name, created_at) VALUES
        ('ac_kept00001', 'human', 'Kept', '2026-01-01T00:00:00.000Z'),
        ('ac_mach00001', 'machine', 'box', '2026-01-01T00:00:00.000Z'),
        ('ac_wrap00001', 'contractor', 'wrapper', '2026-01-01T00:00:00.000Z');
      INSERT INTO machines (id, account_id, name, created_at, grp) VALUES ('mc_00000001', 'ac_mach00001', 'box', '2026-01-01T00:00:00.000Z', 'shared');
      INSERT INTO machine_v2_members (machine_id, grp, created_at) VALUES ('mc_00000001', 'shared', '2026-01-01T00:00:00.000Z');
      INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES ('wrapper-key', 'ac_wrap00001', 'exec-machine contractor', '2026-01-01T00:00:00.000Z');
      INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES ('kept-key', 'ac_kept00001', 'device', '2026-01-01T00:00:00.000Z');
      INSERT INTO group_members (grp, account_id, joined_at) VALUES ('shared', 'ac_wrap00001', '2026-01-01T00:00:00.000Z');
      INSERT INTO read_sessions (token_hash, account_id, created_at, expires_at) VALUES ('read-hash', 'ac_wrap00001', '2026-01-01T00:00:00.000Z', '2027-01-01T00:00:00.000Z');
      INSERT INTO devices (id, account_id, pubkey, installation, kind, name, created_at, last_seen_at) VALUES ('dev_1', 'ac_wrap00001', 'wrapper-key', 'wrapper', 'mac', 'wrapper', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
      INSERT INTO device_commands (device_id, payload, issued_by, created_at) VALUES ('dev_1', '{}', 'ac_wrap00001', '2026-01-01T00:00:00.000Z');
      INSERT INTO message_devices (message_id, device_id) VALUES ('m_1', 'dev_1');
      INSERT INTO personas (name, allocation, pubkey, account_id, created_at) VALUES ('wrapper', 9001, 'wrapper-key', 'ac_wrap00001', '2026-01-01T00:00:00.000Z');
      INSERT INTO join_tokens (token_hash, account_id, capabilities, created_at, expires_at, grp) VALUES ('join-hash', 'ac_wrap00001', 'device', '2026-01-01T00:00:00.000Z', '2027-01-01T00:00:00.000Z', 'shared');
      INSERT INTO sessions (id, allocation, kind, title, tags, created_by, executor, executor_config, created_at, last_activity_at, hold, work, lifecycle, run_state, grp)
        VALUES ('ses_old00001', 1, 'agent', 'old', '[]', 'owner', 'kernel', '{}', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 'normal', 'idle', 'live', 'no_run', 'shared');
      INSERT INTO session_subscriptions (session_id, subscription_id, payload, armed_at) VALUES
        ('ses_old00001', 'timer.keep', '{}', '2026-01-01T00:00:00.000Z'),
        ('ses_old00001', 'park.r-1', '{}', '2026-01-01T00:00:00.000Z');
      """)
      // The retired stores, in the shape a real old space carries them.
      try db.execute(sql: Self.legacySchema)
      try db.execute(sql: "INSERT INTO contractors (name, allocation, account_id, created_at) VALUES ('wrapper', 9001, 'ac_wrap00001', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO contractor_slots (contractor, generation, claimed_at, last_seen) VALUES ('wrapper', 1, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO contractor_rate_limits (contractor, report, reported_at) VALUES ('wrapper', '{}', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO contractor_entries (session_id, physical_session_id, ordinal, kind, payload, received_at) VALUES ('ses_old00001', 'physical', 0, 'entry', '{}', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO claude_code_sessions (session_id, claude_session_id) VALUES ('ses_old00001', 'claude-session')")
      try db.execute(sql: "INSERT INTO claude_code_handovers (session_id, entry_uuid, effect, handed_over_at) VALUES ('ses_old00001', 'entry', 'delivered', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO claude_history_progress (session_id, generation, version, epoch, next_line, offset, count, raw_head, handover_head, summary_position, ready) VALUES ('ses_old00001', 0, 1, 'epoch', 0, 0, 0, 0, 0, 0, 1)")
      try db.execute(sql: "INSERT INTO claude_history_items (session_id, generation, position, payload) VALUES ('ses_old00001', 0, 0, '{}')")
      try db.execute(sql: "INSERT INTO claude_history_seen (session_id, generation, uuid) VALUES ('ses_old00001', 0, 'entry')")
      try db.execute(sql: "INSERT INTO claude_history_calls (session_id, generation, call_id, origin, wuhu) VALUES ('ses_old00001', 0, 'call', 0, 1)")
      try db.execute(sql: "INSERT INTO physical_sessions (session_id, id, started_at) VALUES ('ses_old00001', 'physical', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO session_mirror (seq, session_id, project_key, sdk_session_id, subpath, entry, received_at) VALUES (1, 'ses_old00001', 'project', 'sdk', '', '{}', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "INSERT INTO session_scope_context (session_id, tool_call_id, folders, text) VALUES ('ses_old00001', 'call', '[]', 'text')")
      try db.execute(sql: "INSERT INTO session_watches (session_id, identity, armed, armed_at) VALUES ('ses_old00001', 'owner', 1, '2026-01-01T00:00:00.000Z')")
    }
    // A row an older binary left dangling: the migrations must not validate what they did not write.
    try database.access { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('shared', 'ac_dangling0', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let kept = AccountID(rawValue: "ac_kept00001")
    let upgraded = try Space.open(file: location)
    #expect(try await upgraded.accounts().map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.human, .machine])
    #expect(try await upgraded.accounts().contains { $0.id == kept })
    #expect(try database.access { db in try db.strings("SELECT pubkey FROM account_keys") } == ["kept-key"])
    #expect(try database.access { db in try db.int("SELECT count(*) FROM devices") } == 0)
    #expect(try database.access { db in try db.int("SELECT count(*) FROM device_commands") } == 0)
    #expect(try database.access { db in try db.int("SELECT count(*) FROM message_devices") } == 0)
    #expect(try database.access { db in try db.int("SELECT count(*) FROM personas") } == 0)
    #expect(try database.access { db in try db.int("SELECT count(*) FROM join_tokens") } == 0)
    #expect(try database.access { db in try db.strings("SELECT subscription_id FROM subscription_slots ORDER BY 1") } == ["timer.keep"])
    #expect(try database.access { db in
      try db.int("SELECT count(*) FROM group_roles WHERE account_id = 'ac_wrap00001'")
    } == 0)
    #expect(try database.access { db in
      try db.int("SELECT count(*) FROM group_roles WHERE account_id = 'ac_dangling0'")
    } == 0)
    #expect(try database.access { db in try db.strings("SELECT name FROM sqlite_master WHERE name IN (\(Self.dropped.map { "'" + $0 + "'" }.joined(separator: ","))) ORDER BY 1") } == [])
    let freshFolder = try ScratchFolder("migration-fresh")
    let freshLocation = freshFolder.url.appending(path: "space.sqlite")
    let freshSpace = try Space.open(file: freshLocation)
    let fresh = try RawDatabase(path: freshLocation.path)
    _ = freshSpace.worker
    let migrated = try database.access(Self.schemaShape)
    let expected = try fresh.access(Self.schemaShape)
    #expect(migrated.tables.keys.sorted() == expected.tables.keys.sorted())
    for (table, lines) in expected.tables.sorted(by: { $0.key < $1.key }) {
      #expect(migrated.tables[table] == lines, "\(table)")
    }
    #expect(migrated.indexesAndTriggers == expected.indexesAndTriggers)
    try await upgraded.close()
    try await freshSpace.close()
  }

  @Test func groupsAreNamedAfterTheirAliasAndSharedIsShared() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try Space.open(file: location)
    let owner = try await original.addAccount(kind: .human, name: "Morgan").id
    let lab = try await original.createGroup(alias: "lab", owner: owner)
    await original.stopWorker()
    let offline = database
    try await original.close()
    try offline.access { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('bare', '2026-01-01T00:00:00.000Z')")
      try db.execute(sql: "ALTER TABLE groups DROP COLUMN name")
      try db.execute(sql: "ALTER TABLE groups ADD COLUMN alias TEXT")
      try db.execute(sql: """
      UPDATE groups SET alias = (SELECT name FROM aliases WHERE aliases.kind = 'group' AND aliases.target = groups.id AND aliases.current)
      """)
      try db.execute(sql: "ALTER TABLE aliases DROP COLUMN current")
      try db.execute(sql: "ALTER TABLE groups ADD COLUMN personal_account TEXT")
      try Migration015.apply(db)
      try db.execute(sql: "ALTER TABLE groups DROP COLUMN personal_account")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '043'")
    }
    let upgraded = try Space.open(file: location)
    let names = Dictionary(uniqueKeysWithValues: try await upgraded.groups().map { ($0.id, $0.name) })
    #expect(names == [.shared: "Shared", .settings: "settings", lab: "lab", GroupID(rawValue: "bare"): "bare"])
    try await upgraded.close()
  }

  @Test func newerDatabaseIsRefusedWithoutChanges() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try Space.open(file: location)
    let applied = { try database.access { try $0.strings("SELECT identifier FROM grdb_migrations ORDER BY identifier") } }
    let known = try applied()
    try database.access { db in try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('998'), ('999')") }
    #expect(throws: SpaceError.unknownMigrations(["998", "999"])) { try Space.open(file: location) }
    #expect(try applied() == known + ["998", "999"])
    try await original.close()
  }

  @Test(arguments: [false, true]) func machineV2IndexesUpgradeWithOrWithoutExistingIndexes(existingIndexes: Bool) async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let database = try RawDatabase(path: location.path)
    let original = try Space.open(file: location)
    try database.access { db in
      try LegacyMachineSchema.create(in: db)
      if existingIndexes { try Migration011.apply(db) }
      try Migration011.apply(db)
    }
    #expect(try database.access { db in
      try db.strings("SELECT name FROM pragma_index_info('machine_v2_operations_admission') ORDER BY seqno")
    } == ["machine_id", "active", "reserved_bytes"])
    #expect(try database.access { db in
      try db.strings("SELECT name FROM pragma_index_info('machine_v2_channels_by_operation') ORDER BY seqno")
    } == ["operation_id"])
    try await original.close()
  }

  @Test func fileBackedWriterHasThePageCache() async throws {
    let folder = try ScratchFolder("page-cache")
    let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
    #expect(try space.database.accessWriter(label: "test.writer") { try MigrationDB(handle: $0).int("PRAGMA cache_size") } == -PageCache.writerKiB)
    let (mmap, cap) = try space.database.accessWriter(label: "test.writer") { handle in
      let db = MigrationDB(handle: handle)
      return try (db.int("PRAGMA mmap_size"), db.string(Self.mmapCap))
    }
    let limit = cap.flatMap { $0.hasPrefix("0x") ? Int($0.dropFirst(2), radix: 16) : Int($0) } ?? PageCache.mmapBytes
    #expect(mmap == min(PageCache.mmapBytes, limit))
    #expect(mmap ?? 0 >= 1 << 30)
    try await space.close()
  }

  @Test func fileBackedWriterDoesNotZeroFreedPages() async throws {
    let folder = try ScratchFolder("secure-delete")
    let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
    #expect(try space.database.accessWriter(label: "test.writer") { try MigrationDB(handle: $0).int("PRAGMA secure_delete") } == 0)
    try await space.close()
  }

  @Test func eachMigrationAnUpgradeAppliesIsLoggedBeforeAndAfterWithItsDuration() async throws {
    let folder = try ScratchFolder("migration")
    let location = folder.url.appending(path: "space.sqlite")
    let original = try await baseline(location)
    let logs = RecordedLogs()
    let upgraded = try Space.open(file: location, log: logs.logger)
    #expect(logs.all.map(\.message).filter { $0.hasPrefix("migration ") } == ["001", "002", "005", "042"].flatMap { ["migration \($0): applying", "migration \($0): applied in 0 ms"] })
    try await upgraded.close()
    try await original.close()
  }

  static let mmapCap = "SELECT substr(compile_options, 15) FROM pragma_compile_options WHERE compile_options LIKE 'MAX!_MMAP!_SIZE=%' ESCAPE '!'"
}

private struct LegacyExec: Equatable {
  let id: String
  let toolSpec: String?
}

private extension Space {
  func owedExecs() async throws -> [LegacyExec] {
    try RawDatabase.open(databasePath) { db in
      try db.rows("SELECT id, tool_spec FROM machine_execs WHERE tool_end_owed = 1 ORDER BY started_at, id").map {
        LegacyExec(id: $0["id"], toolSpec: $0["tool_spec"])
      }
    }
  }
}
