import DeterministicDependencies
#if canImport(FoundationEssentials)
  import class Foundation.FileHandle
  import class Foundation.Process
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Scratch
import struct SpaceContract.GroupID
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

// The shipped compaction over a copy of the pre-groups Backcompat fixture: the
// same file and steps the rehearsal on a copy of a live space's database runs.
@Suite(.deterministicDependencies) struct Wuhu45MigrationTests {
  static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Backcompat/pre-ledger.sqlite")
  static let boss = AccountID(rawValue: "ac_b0ss0000")
  static let carol = AccountID(rawValue: "ac_car01000")

  func scratch() throws -> URL {
    let folder = try scratchURL("wuhu45")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  func copy(to folder: URL, seeding sql: String = "") throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "space.sqlite")
    try Data(contentsOf: Self.fixture).write(to: file)
    if !sql.isEmpty { try RawDatabase.open(file.path) { db in try db.execute(sql: sql) } }
    return file
  }

  // boss: an admin with two personas; carol: a person who is not an admin.
  static let people = """
  INSERT INTO accounts (id, kind, name, is_admin, created_at) VALUES
    ('ac_b0ss0000', 'human', 'boss', 1, '2026-01-01T00:00:00.000Z'),
    ('ac_car01000', 'human', 'carol', 0, '2026-01-02T00:00:00.000Z');
  INSERT INTO personas (name, allocation, pubkey, account_id, created_at) VALUES
    ('amber-river-stone', 900, 'k1', 'ac_b0ss0000', '2026-01-01T00:00:00.000Z'),
    ('maple-cloud-drift', 902, 'k3', 'ac_b0ss0000', '2026-01-03T00:00:00.000Z'),
    ('cedar-lake-ember', 901, 'k2', 'ac_car01000', '2026-01-02T00:00:00.000Z');
  """

  // Tables migration 002 removes: the removed executors' stores and the stores that predate the current schema.
  static let dropped: Set = [
    "claude_code_handovers", "claude_code_sessions", "claude_history_calls", "claude_history_items",
    "claude_history_progress", "claude_history_seen", "contractor_entries", "contractor_rate_limits",
    "contractor_slots", "contractors", "exec_jobs", "physical_sessions", "session_mirror",
    "session_scope_context", "session_watches",
  ]

  @Test func everyAdminStaysAnAdminWhileEmptyLegacyGroupsDisappear() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder, seeding: Self.people)
    let admins = try RawDatabase.open(file.path) {
      try $0.strings("SELECT id FROM accounts WHERE is_admin = 1 AND removed_at IS NULL")
    }
    #expect(admins == [Self.boss.rawValue])
    try Wuhu45Migration.apply(to: file)
    let space = try Space.open(file: file)
    #expect(try await Set(space.accounts().filter(\.isAdmin).map(\.id.rawValue)) == Set(admins))
    #expect(try await Set(space.groups().map(\.id)) == [.shared, .settings])
    #expect(try await space.isHumanAdmin(Self.boss, of: .shared))
    #expect(try await !space.isHumanAdmin(Self.carol, of: .shared))
    #expect(try await space.memberGroups(of: Self.carol) == [.shared])
    #expect(try await space.reads(.shared) == [.shared, .settings])
    try await space.close()
  }

  @Test func anAdminWithoutAPersonaAbortsAndLeavesTheFileAsItWas() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(
      to: folder,
      seeding: "INSERT INTO accounts (id, kind, name, is_admin, created_at) VALUES ('ac_n0pers00', 'human', 'nobody', 1, '2026-01-01T00:00:00.000Z')",
    )
    let before = try Self.snapshot(file)
    #expect(throws: MigrationFailure.self) { try Wuhu45Migration.apply(to: file) }
    #expect(try Self.snapshot(file) == before)
    #expect(try !Wuhu45Migration.isApplied(to: file))
    #expect(throws: SpaceError.needsMigration("wuhu-45")) { try Space.open(file: file) }
  }

  @Test func theMigratedSchemaMatchesFreshWithRetiredTablesRetained() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder)
    try Wuhu45Migration.apply(to: file)
    let fresh = folder.appending(path: "fresh/space.sqlite")
    try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await Space.open(file: fresh).close()
    let migrated = try Self.shape(file)
    let expected = try Self.shape(fresh)
    // Tables added after the groups migration come with the next open, IF NOT EXISTS.
    let later: Set = ["grdb_migrations", "session_model_routes", "session_model_route_history", "revision_actors", "space_deployment_certificate", "inferences", "conversation_titles", "attachments", "machine_v2_members", "machine_presence", "machine_descriptions", "machine_operations", "machine_file_operations", "aliases", "session_command_tokens", "session_worker_incarnations", "execution_worker_owners", "session_worker_assignments", "worker_script_owners", "join_token_receipts", "message_viewing", "session_blobs", "group_roles", "session_prompts", "requests", "subscription_slots", "subscription_firings", "wmd_snapshots", "wmd_log", "wmd_checkpoints", "document_state", "document_snapshot", "document_log", "document_checkpoint", "document_lineage", "document_pending_checkpoint", "usage_window_resets", "wuwei_addressable", "wuwei_mail", "wuwei_job", "wuwei_schema", "notifications_retired", "session_lines", "bucket_objects", "person_hidden_sidebars"]
    let retired: Set = ["claude_code_sessions", "claude_code_handovers", "session_scope_context", "exec_jobs"]
    let dropped: Set = ["session_receipts", "session_api_receipts", "session_space_layer", "group_edges", "group_members", "group_reads", "group_epoch", "session_prompt_revisions", "session_subscriptions", "session_commands", "machine_execs", "script_execs", "blobs", "blob_objects"]
    let addsOwnership: Set = ["accounts", "account_keys", "join_tokens", "read_sessions", "personas", "devices", "join_token_receipts"]
    let migratedKeys = Set(migrated.keys).subtracting(retired).subtracting(dropped)
    let expectedKeys = Set(expected.keys).subtracting(later)
    #expect(
      migratedKeys == expectedKeys,
      "migrated only: \(migratedKeys.subtracting(expectedKeys).sorted()); fresh only: \(expectedKeys.subtracting(migratedKeys).sorted())",
    )
    // `groups`, `accounts`, `machines`, `messages`, `sessions` and `session_queue` are reshaped
    // by the next migrations; the reopened comparison below pins their columns.
    for (table, fresh) in expected.sorted(by: { $0.key < $1.key })
      where !later.contains(table) && !["groups", "accounts", "machines", "messages", "sessions", "user_profiles", "revisions", "session_queue"].contains(table)
    {
      var wanted = fresh
      wanted.columns = wanted.columns.filter { Self.keeps($0, for: table, addsOwnership) }
      wanted.indexes = wanted.indexes.filter { Self.keeps($0, for: table, addsOwnership) }
      wanted.foreignKeys = wanted.foreignKeys.filter { Self.keeps($0, for: table, addsOwnership) }
      wanted.triggers = wanted.triggers.filter { Self.keeps($0, for: table, addsOwnership) }
      #expect(migrated[table] == wanted, "\(table)")
    }
    try await Space.open(file: file).close()
    let reopened = try Self.shape(file)
    #expect(reopened["session_space_layer"] == nil)
    #expect(reopened.filter { !retired.contains($0.key) } == expected)
    for table in retired {
      #expect(reopened[table] == nil)
    }
    let fileSchema = try #require(reopened["machine_file_operations"])
    #expect(fileSchema.indexes.allSatisfy { !Self.name($0.row).contains("machine_file_operations_live") })
    #expect(fileSchema.triggers.allSatisfy { !$0.contains("machine_file_operations_live") })
    try await Space.open(file: file).close()
    #expect(try Self.shape(file) == reopened)
  }

  // A read session binds the web host it was minted on: a nullable grp, NULL
  // being shared, alike whether the server created the schema or migrated it.
  @Test func everyRowIsKeptInShared() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder, seeding: Self.people)
    let (before, userTables, sequence) = try RawDatabase.open(file.path) { db in
      var rows: [String: (columns: [String], rows: [[Wuwei.Value]])] = [:]
      for table in try Self.tables(db) where table != "session_scope_context" && !Self.dropped.contains(table) {
        let columns = try Self.columns(of: table, in: db).filter { !(table == "accounts" && $0 == "is_admin") }
        rows[table] = try (columns, Self.rows(table, columns, in: db))
      }
      var userTables: [String: [[Wuwei.Value]]] = [:]
      for path in try db.strings("SELECT path FROM tables") {
        userTables["shared:" + path] = try Self.rows(path, Self.columns(of: path, in: db), in: db)
      }
      let sequence = try db.rows("SELECT name, seq FROM sqlite_sequence").reduce(into: [String: Int64]()) {
        let name: String = $1["name"]
        let seq: Int64 = $1["seq"]
        $0[name.hasPrefix("/") ? "shared:" + name : name] = seq
      }
      return (rows, userTables, sequence)
    }
    #expect(!userTables.isEmpty)
    try Wuhu45Migration.apply(to: file)
    try RawDatabase.open(file.path) { db in
      for (table, old) in before.sorted(by: { $0.key < $1.key }) {
        #expect(try Self.rows(table, old.columns, in: db) == old.rows, "\(table)")
        if try Self.columns(of: table, in: db).contains("grp") {
          #expect(try db.int("SELECT count(*) FROM \"\(table)\" WHERE grp <> 'shared'") == 0, "\(table)")
        }
      }
      for (table, rows) in userTables {
        #expect(try Self.rows(table, Self.columns(of: table, in: db), in: db) == rows, "\(table)")
      }
      let after = try db.rows("SELECT name, seq FROM sqlite_sequence").reduce(into: [String: Int64]()) {
        let name: String = $1["name"]
        let seq: Int64 = $1["seq"]
        $0[name] = seq
      }
      #expect(after == sequence)
      #expect(try db.strings("PRAGMA integrity_check") == ["ok"])
      #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
    }
  }

  @Test func aPreGroupsBinaryFailsToOpenTheMigratedFile() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder)
    try Wuhu45Migration.apply(to: file)
    // The statement from the pre-groups schema script.
    #expect(throws: MigrationFailure.self) {
      try RawDatabase.open(file.path) { db in
        try db.execute(sql: #"CREATE INDEX IF NOT EXISTS "fs_heads_by_parent" ON "fs_heads" ("parent_path");"#)
      }
    }
  }

  // The CLI runs every statement it is given unless told to bail, so the
  // file tells it: a failed guard must not be followed by the COMMIT.
  @Test func theScriptBailsOnItsOwn() throws {
    let script = try String(contentsOf: Wuhu45Migration.script, encoding: .utf8)
    #expect(script.split(separator: "\n").first == ".bail on")
  }

  static let sqlite3: URL? = (
    ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
      + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init),
  )
  .map { URL(fileURLWithPath: $0).appending(path: "sqlite3") }
  .first { FileManager.default.isExecutableFile(atPath: $0.path) }

  static func cli(_ script: String, on file: URL, in folder: URL) throws -> Int32 {
    let input = folder.appending(path: "wuhu45.sql")
    try script.write(to: input, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = Self.sqlite3
    process.arguments = [file.path]
    process.standardInput = try FileHandle(forReadingFrom: input)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @Test(.enabled(if: sqlite3 != nil)) func throughThePlainCLIAFailedGuardLeavesTheFileByteIdentical() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(
      to: folder,
      seeding: "INSERT INTO accounts (id, kind, name, is_admin, created_at) VALUES ('ac_n0pers00', 'human', 'nobody', 1, '2026-01-01T00:00:00.000Z')",
    )
    let before = try Data(contentsOf: file)
    #expect(try Self.cli(Wuhu45Migration.spliced(for: file), on: file, in: folder) != 0)
    #expect(try Data(contentsOf: file) == before)

    let clean = try copy(to: folder.appending(path: "clean"))
    #expect(try Self.cli(Wuhu45Migration.spliced(for: clean), on: clean, in: folder) == 0)
    #expect(try Wuhu45Migration.isApplied(to: clean))
    try await Space.open(file: clean).close()
  }

  static func tables(_ db: MigrationDB) throws -> [String] {
    try db.strings("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%.table' ORDER BY name")
  }

  static func columns(of table: String, in db: MigrationDB) throws -> [String] {
    try db.strings("SELECT name FROM pragma_table_info(?) ORDER BY cid", arguments: [table])
  }

  static func rows(_ table: String, _ columns: [String], in db: MigrationDB) throws -> [[Wuwei.Value]] {
    let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
    return try db.rows("SELECT \(list) FROM \"\(table)\" ORDER BY \(list)").map { $0.values }
  }

  /// A pragma row as its typed values by column name.
  typealias ShapeRow = [String: Wuwei.Value]

  struct IndexShape: Equatable {
    let row: ShapeRow
    let keys: [ShapeRow]
  }

  struct TableShape: Equatable {
    var columns: [ShapeRow]
    var indexes: [IndexShape]
    var foreignKeys: [ShapeRow]
    var triggers: [String]
  }

  struct Snapshot: Equatable {
    let schema: [String]
    let accounts: [ShapeRow]
  }

  static func shapeRow(_ row: MigrationRow) -> ShapeRow {
    Dictionary(uniqueKeysWithValues: zip(row.columns, row.values))
  }

  /// The `name` a pragma row carries, for the filters the comparison applies.
  static func name(_ row: ShapeRow) -> String {
    guard case let .text(name)? = row["name"] else { return "" }
    return name
  }

  static func mentions(_ row: ShapeRow, _ text: String) -> Bool {
    row.values.contains { if case let .text(value) = $0 { value.contains(text) } else { false } }
  }

  /// Names the fresh schema has and the migrated one does not: the columns the script renames or replaces, and the indexes that name them.
  static let laterNames = ["claude_code_handovers_by_session", "session_contents_assistant_history", "session_pointers_by_content", "_alias_insert", "_alias_update", "owner_account"]

  /// Whether the fresh table's component stays for comparison; `addsOwnership` tables gain `owner` and its indexes later, and `session_runtime` gains `step_try`.
  static func keeps(_ column: ShapeRow, for table: String, _ addsOwnership: Set<String>) -> Bool {
    laterNames.allSatisfy { !mentions(column, $0) }
      && !(addsOwnership.contains(table) && mentions(column, "owner"))
      && !(table == "session_runtime" && mentions(column, "step_try"))
  }

  static func keeps(_ index: IndexShape, for table: String, _ addsOwnership: Set<String>) -> Bool {
    keeps(index.row, for: table, addsOwnership) && index.keys.allSatisfy { keeps($0, for: table, addsOwnership) }
  }

  static func keeps(_ trigger: String, for table: String, _ addsOwnership: Set<String>) -> Bool {
    laterNames.allSatisfy { !trigger.contains($0) } && !(addsOwnership.contains(table) && trigger.contains("owner"))
  }

  static func snapshot(_ file: URL) throws -> Snapshot {
    try RawDatabase.open(file.path) { db in
      let schema = try db.strings("SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY type, name")
      let accounts = try db.rows("SELECT * FROM accounts ORDER BY id").map(shapeRow)
      return Snapshot(schema: schema, accounts: accounts)
    }
  }

  // Columns, indexes, foreign keys and triggers of every space table.
  static func shape(_ file: URL) throws -> [String: TableShape] {
    try RawDatabase.open(file.path) { db in
      var shape: [String: TableShape] = [:]
      for table in try tables(db) where !table.contains(":/") {
        let columns = try db.rows(
          #"SELECT cid, name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?) ORDER BY cid"#,
          arguments: [table],
        ).map(shapeRow)
        var indexes: [IndexShape] = []
        for index in try db.rows(
          #"SELECT name, "unique", origin, partial FROM pragma_index_list(?) ORDER BY name"#, arguments: [table],
        ) {
          let name: String = index["name"]
          let keys = try db.rows(
            #"SELECT seqno, cid, name, "desc", coll, "key" FROM pragma_index_xinfo(?) ORDER BY seqno"#, arguments: [name],
          ).map(shapeRow)
          indexes.append(IndexShape(row: shapeRow(index), keys: keys))
        }
        let foreignKeys = try db.rows(
          #"SELECT id, seq, "table", "from", "to", on_update, on_delete, "match" FROM pragma_foreign_key_list(?) ORDER BY id, seq"#,
          arguments: [table],
        ).map(shapeRow)
        let triggers = try db.strings(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name", arguments: [table],
        )
        shape[table] = TableShape(columns: columns, indexes: indexes, foreignKeys: foreignKeys, triggers: triggers)
      }
      return shape
    }
  }
}

final class Warnings: Sendable {
  private let entries = Mutex<[String]>([])

  var messages: [String] { entries.withLock { $0 } }

  var logger: Logger { Logger(label: "test") { _ in Handler(sink: self) } }

  private struct Handler: LogHandler {
    let sink: Warnings
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
      guard event.level == .warning else { return }
      sink.entries.withLock { $0.append(event.message.description) }
    }
  }
}
