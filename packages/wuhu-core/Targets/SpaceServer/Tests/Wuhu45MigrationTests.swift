import Foundation
import GRDB
import Logging
import Scratch
import struct SpaceContract.GroupID
import SpaceCore
import Synchronization
import Testing

// The shipped compaction over a copy of the pre-groups Backcompat fixture: the
// same file and steps the rehearsal on a copy of a live space's database runs.
@Suite struct Wuhu45MigrationTests {
  static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Backcompat/space.sqlite")
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
    if !sql.isEmpty { try DatabaseQueue(path: file.path).write { db in try db.execute(sql: sql) } }
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

  @Test func everyAdminStaysAnAdminThroughTheirPersonalGroup() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder, seeding: Self.people)
    let admins = try await DatabaseQueue(path: file.path).read { db in
      try String.fetchAll(db, sql: "SELECT id FROM accounts WHERE is_admin = 1 AND removed_at IS NULL")
    }
    #expect(admins == [Self.boss.rawValue])
    try Wuhu45Migration.apply(to: file)
    let space = try Space.open(file: file)
    #expect(try await Set(space.accounts().filter(\.isAdmin).map(\.id.rawValue)) == Set(admins))
    let bosses = GroupID(rawValue: "amber-river-stone")
    let carols = GroupID(rawValue: "cedar-lake-ember")
    #expect(try await space.personalGroup(of: Self.boss) == bosses)
    #expect(try await space.personalGroup(of: Self.carol) == carols)
    #expect(try await Set(space.groups().map(\.id)) == [.shared, bosses, carols])
    #expect(try await space.isHumanAdmin(Self.boss, of: .shared))
    #expect(try await !space.isHumanAdmin(Self.carol, of: .shared))
    #expect(try await space.isHumanAdmin(Self.carol, of: carols))
    #expect(try await !space.isHumanAdmin(Self.carol, of: bosses))
    #expect(try await space.reads(carols) == [carols, .shared])
    #expect(try await space.reads(.shared) == [.shared])
  }

  @Test func anAdminWithoutAPersonaAbortsAndLeavesTheFileAsItWas() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(
      to: folder,
      seeding: "INSERT INTO accounts (id, kind, name, is_admin, created_at) VALUES ('ac_n0pers00', 'human', 'nobody', 1, '2026-01-01T00:00:00.000Z')",
    )
    let before = try Self.snapshot(file)
    #expect(throws: DatabaseError.self) { try Wuhu45Migration.apply(to: file) }
    #expect(try Self.snapshot(file) == before)
    #expect(try !Wuhu45Migration.isApplied(to: file))
    #expect(throws: SpaceError.needsMigration("wuhu-45")) { try Space.open(file: file) }
  }

  @Test func theMigratedSchemaMatchesFreshWithRetiredTablesRetained() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder)
    try Wuhu45Migration.apply(to: file)
    let fresh = folder.appending(path: "fresh/space.sqlite")
    try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try Space.open(file: fresh)
    let migrated = try Self.shape(file)
    let expected = try Self.shape(fresh)
    // Tables added after the groups migration come with the next open, IF NOT EXISTS.
    let later: Set = ["revision_actors", "space_deployment_certificate", "inferences"]
    let retired: Set = ["claude_code_sessions", "claude_code_handovers"]
    #expect(migrated.keys.filter { !retired.contains($0) }.sorted() == expected.keys.filter { !later.contains($0) }.sorted())
    for (table, lines) in expected.sorted(by: { $0.key < $1.key }) where !later.contains(table) {
      #expect(migrated[table] == lines.filter { line in
        !["claude_code_handovers_by_session", "session_contents_assistant_history", "session_pointers_by_content"].contains(where: line.contains)
      }, "\(table)")
    }
    _ = try Space.open(file: file)
    let reopened = try Self.shape(file)
    #expect(reopened.filter { !retired.contains($0.key) } == expected)
    for table in retired {
      #expect(reopened[table] == migrated[table])
    }
  }

  // A read session binds the web host it was minted on: a nullable grp, NULL
  // being shared, alike whether the server created the schema or migrated it.
  @Test func everyRowIsKeptInShared() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder, seeding: Self.people)
    let (before, userTables, sequence) = try DatabaseQueue(path: file.path).read { db in
      var rows: [String: (columns: [String], rows: [[DatabaseValue]])] = [:]
      for table in try Self.tables(db) where table != "session_scope_context" {
        let columns = try Self.columns(of: table, in: db).filter { !(table == "accounts" && $0 == "is_admin") }
        rows[table] = try (columns, Self.rows(table, columns, in: db))
      }
      var userTables: [String: [[DatabaseValue]]] = [:]
      for path in try String.fetchAll(db, sql: "SELECT path FROM tables") {
        userTables["shared:" + path] = try Self.rows(path, Self.columns(of: path, in: db), in: db)
      }
      let sequence = try Row.fetchAll(db, sql: "SELECT name, seq FROM sqlite_sequence").reduce(into: [String: Int64]()) {
        let name: String = $1["name"]
        $0[name.hasPrefix("/") ? "shared:" + name : name] = $1["seq"]
      }
      return (rows, userTables, sequence)
    }
    #expect(!userTables.isEmpty)
    try Wuhu45Migration.apply(to: file)
    try DatabaseQueue(path: file.path).read { db in
      for (table, old) in before.sorted(by: { $0.key < $1.key }) {
        #expect(try Self.rows(table, old.columns, in: db) == old.rows, "\(table)")
        if try Self.columns(of: table, in: db).contains("grp") {
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\" WHERE grp <> 'shared'") == 0, "\(table)")
        }
      }
      for (table, rows) in userTables {
        #expect(try Self.rows(table, Self.columns(of: table, in: db), in: db) == rows, "\(table)")
      }
      let after = try Row.fetchAll(db, sql: "SELECT name, seq FROM sqlite_sequence").reduce(into: [String: Int64]()) {
        $0[$1["name"]] = $1["seq"]
      }
      #expect(after == sequence)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM session_scope_context") == 0)
      #expect(try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"])
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  @Test func aPreGroupsBinaryFailsToOpenTheMigratedFile() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder)
    try Wuhu45Migration.apply(to: file)
    // The statement from the pre-groups schema script.
    #expect(throws: DatabaseError.self) {
      try DatabaseQueue(path: file.path).write { db in
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
    process.executableURL = try #require(sqlite3)
    process.arguments = [file.path]
    process.standardInput = try FileHandle(forReadingFrom: input)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @Test(.enabled(if: sqlite3 != nil)) func throughThePlainCLIAFailedGuardLeavesTheFileByteIdentical() throws {
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
    _ = try Space.open(file: clean)
  }

  @Test func theFirstServeReinducesDocumentsAndSkipsUnreadableBlobs() async throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = try copy(to: folder)
    try Wuhu45Migration.apply(to: file)
    let logs = Warnings()
    let space = try Space.open(file: file, log: logs.logger)
    _ = try await space.fs(.shared).write(
      "/notes/c.md", Data("---\nowner: ann\n---\n# C\n\n[b](wuhu:/notes/b.md) [p](wuhu://alice.localspace/plan.md)\n".utf8),
      ifMatch: nil,
    )
    let raw = try DatabaseQueue(path: file.path)
    // What an older parser left: no rows for c, a stale row for a doc whose blob is gone, and neither run recorded.
    try await raw.write { db in
      try db.execute(sql: """
      DELETE FROM docs WHERE grp = 'shared' AND path = '/notes/c.md';
      DELETE FROM links WHERE grp = 'shared' AND src = '/notes/c.md';
      DELETE FROM doc_custom_attrs WHERE grp = 'shared' AND path = '/notes/c.md';
      DELETE FROM schema_compactions WHERE name = 'wuhu-45-links';
      INSERT INTO fs_heads (grp, path, parent_path, kind, blob_hash, size, line_count, etag, rev, mtime) VALUES
        ('shared', '/missing.md', '/', 'file', '\(String(repeating: "f", count: 64))', 1, 1, 'e1', 1, '2026-01-01T00:00:00.000Z'),
        ('shared', '/unreadable.md', '/', 'file', '\(String(repeating: "e", count: 64))', 1, 1, 'e2', 1, '2026-01-01T00:00:00.000Z');
      INSERT INTO blob_objects (hash, object_key, size, line_count) VALUES
        ('\(String(repeating: "e", count: 64))', 'blobs/ee/ee/\(String(repeating: "e", count: 64))', 1, 1);
      INSERT INTO docs (grp, path, title) VALUES ('shared', '/missing.md', 'stale');
      """)
    }

    try await space.reindexLinks()

    let rows = try await raw.read { db in
      try [
        String.fetchAll(db, sql: "SELECT dst_grp || ' ' || dst FROM links WHERE grp = 'shared' AND src = '/notes/c.md' ORDER BY dst_grp"),
        String.fetchAll(db, sql: "SELECT name || ' ' || value FROM doc_custom_attrs WHERE grp = 'shared' AND path = '/notes/c.md'"),
        String.fetchAll(db, sql: "SELECT path || ' ' || title FROM docs WHERE grp = 'shared' AND path IN ('/notes/c.md', '/missing.md') ORDER BY path"),
        String.fetchAll(db, sql: "SELECT name FROM schema_compactions ORDER BY name"),
      ]
    }
    #expect(rows == [
      ["alice /plan.md", "shared /notes/b.md"],
      [#"owner "ann""#],
      ["/missing.md stale", "/notes/c.md c.md"],
      ["wuhu-45", "wuhu-45-links"],
    ])
    let skipped = logs.messages
    #expect(skipped.count == 2)
    #expect(skipped.contains { $0.contains("shared:/missing.md") })
    #expect(skipped.contains { $0.contains("shared:/unreadable.md") })
  }

  static func tables(_ db: Database) throws -> [String] {
    try String.fetchAll(
      db,
      sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%.table' ORDER BY name",
    )
  }

  static func columns(of table: String, in db: Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?) ORDER BY cid", arguments: [table])
  }

  static func rows(_ table: String, _ columns: [String], in db: Database) throws -> [[DatabaseValue]] {
    let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
    return try Row.fetchAll(db, sql: "SELECT \(list) FROM \"\(table)\" ORDER BY \(list)").map { Array($0.databaseValues) }
  }

  static func snapshot(_ file: URL) throws -> [String] {
    try DatabaseQueue(path: file.path).read { db in
      let schema = try String.fetchAll(db, sql: "SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY type, name")
      let accounts = try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY id").map(\.description)
      return schema + accounts
    }
  }

  // Columns, indexes, foreign keys and triggers of every space table.
  static func shape(_ file: URL) throws -> [String: [String]] {
    try DatabaseQueue(path: file.path).read { db in
      var shape: [String: [String]] = [:]
      for table in try tables(db) where !table.contains(":/") {
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
