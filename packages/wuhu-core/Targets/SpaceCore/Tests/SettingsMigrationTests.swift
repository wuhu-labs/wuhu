import DeterministicDependencies
import Foundation
import GRDB
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

// Migration 003 over a database built by the real Migration001: a team group
// that administered itself and shared, a personal group with an old
// machine-account membership and incoming read edges, and read-closure rows no
// edge justifies.
@Suite(.deterministicDependencies) struct SettingsMigrationTests {
  @Test func upgradeCopiesCatalogsAndDeletesTheEmptyLegacyGroup() async throws {
    let database = try DatabaseQueue(path: "file:/settings-migration-\(UUID())?vfs=memdb")
    try await database.write { db in
      try Migration001.apply(db)
      try db.execute(sql: """
      CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
      INSERT INTO grdb_migrations VALUES ('001');
      INSERT INTO accounts (id, kind, name, created_at) VALUES ('person', 'human', 'Owner', '2026-01-01T00:00:00Z');
      INSERT INTO accounts (id, kind, name, created_at) VALUES ('machine-account', 'machine', 'Box', '2026-01-01T00:00:00Z');
      INSERT INTO accounts (id, kind, name, created_at) VALUES ('operator', 'human', 'Operator', '2026-01-01T00:00:00Z');
      INSERT INTO accounts (id, kind, name, created_at, removed_at) VALUES ('gone', 'human', 'Gone', '2026-01-01T00:00:00Z', '2026-03-01T00:00:00Z');
      INSERT INTO groups (id, created_at) VALUES ('gone-group', '2026-01-01T00:00:00Z');
      INSERT INTO group_members VALUES ('gone-group', 'gone', '2026-01-01T00:00:00Z');
      INSERT INTO group_edges VALUES ('gone-group', 'gone-group', 'admin', '2026-01-01T00:00:00Z', NULL), ('gone-group', 'shared', 'admin', '2026-01-01T00:00:00Z', NULL);
      INSERT INTO groups (id, created_at) VALUES ('ops', '2026-02-01T00:00:00Z');
      INSERT INTO group_members VALUES ('ops', 'person', '2026-02-01T00:00:00Z'), ('ops', 'operator', '2026-02-01T00:00:00Z');
      INSERT INTO group_edges VALUES ('ops', 'ops', 'admin', '2026-02-01T00:00:00Z', NULL), ('ops', 'shared', 'admin', '2026-02-01T00:00:00Z', NULL);
      INSERT INTO groups (id, created_at) VALUES ('personal', '2026-01-01T00:00:00Z');
      INSERT INTO group_members VALUES ('personal', 'person', '2026-01-01T00:00:00Z'), ('shared', 'person', '2026-01-01T00:00:00Z'), ('shared', 'operator', '2026-01-01T00:00:00Z');
      INSERT INTO group_edges VALUES ('personal', 'personal', 'admin', '2026-01-01T00:00:00Z', NULL), ('personal', 'shared', 'admin', '2026-01-01T00:00:00Z', NULL), ('personal', 'shared', 'read', '2026-01-01T00:00:00Z', NULL);
      INSERT INTO group_edges VALUES ('shared', 'personal', 'read', '2026-01-01T00:00:00Z', NULL), ('personal', 'ops', 'read', '2026-01-01T00:00:00Z', NULL);
      INSERT INTO group_reads VALUES ('shared', 'personal', 'shared->personal'), ('shared', 'ops', 'shared->personal');
      """)
      let content = Data("{}".utf8)
      let hash = String(repeating: "a", count: 64)
      try db.execute(sql: "INSERT INTO blobs (hash, content) VALUES (?, ?)", arguments: [hash, content])
      for path in ["/models.json", "/model-groups.json", "/capabilities.json", "/machine-v2-upgrade.json"] {
        try db.execute(sql: "INSERT INTO revisions (mtime, grp) VALUES ('2026-01-01T00:00:00Z', 'shared')")
        let rev = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO fs_versions (grp, path, rev, kind, blob_hash, op) VALUES ('shared', ?, ?, 'file', ?, 'write')", arguments: [path, rev, hash])
        try db.execute(sql: "INSERT INTO fs_heads VALUES ('shared', ?, '/', 'file', ?, 2, 1, ?, ?, '2026-01-01T00:00:00Z')", arguments: [path, hash, hash, rev])
      }
    }
    // A row an older binary left behind: 003 must not validate what it did not write.
    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES ('ops', 'ghost', '2026-02-01T00:00:00Z')")
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    let space = try Space(writer: database)
    let owner = AccountID(rawValue: "person")
    let operatorAccount = AccountID(rawValue: "operator")
    let machine = AccountID(rawValue: "machine-account")
    // The old shared admin and the team's admins carry over; a machine never
    // becomes one.
    #expect(try await space.account(owner)?.isAdmin == true)
    #expect(try await space.account(operatorAccount)?.isAdmin == true)
    #expect(try await space.account(machine)?.isAdmin == false)
    let personal = GroupID(rawValue: "personal")
    let ops = GroupID(rawValue: "ops")
    #expect(try await space.group(personal) == nil)
    #expect(try await space.group(ops)?.visibility == .private)
    let removed = AccountID(rawValue: "gone")
    #expect(try await !space.isHumanAdmin(removed, of: .shared))
    #expect(space.cell.memberGroups(of: removed).isEmpty)
    #expect(space.cell.memberGroups(of: AccountID(rawValue: "ghost")).isEmpty)
    #expect(space.cell(of: ops).grants().filter { $0.role == .admin }.map(\.id).sorted() == ["operator", "person"])
    #expect(try await space.isHumanAdmin(owner, of: ops))
    #expect(try await !space.isHumanAdmin(operatorAccount, of: personal))
    #expect(try await !space.isHumanAdmin(owner, of: personal))
    #expect(try await space.reads(.shared) == [.shared, .settings])
    // The settings group holds the catalogs; shared's copies are ordinary
    // file deletes, still in the journal.
    for path in ["/models.json", "/model-groups.json", "/capabilities.json", "/machine-v2-upgrade.json"] {
      #expect(try await space.fs(.settings).read(path).1 == Data("{}".utf8))
      await #expect(throws: SpaceError.notFound(path)) { _ = try await space.fs(.shared).read(path) }
      #expect(try await space.history(try SpacePath(validating: path), in: .shared).last?.2 == .delete)
    }
    let copied = try await space.fs(.settings).read("/models.json")
    _ = try await space.fs(.settings).write("/models.json", Data("{\"edited\":true}".utf8), ifMatch: copied.0)
    let reopened = try Space(writer: database)
    #expect(try await reopened.fs(.settings).read("/models.json").1 == Data("{\"edited\":true}".utf8))
  }
}
