import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LoopCore
import Scratch
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

// Migration 004 over the shape migration 003 leaves: group edges, the read
// closure, the admin rows and personal groups become one access table.
@Suite(.deterministicDependencies) struct AccessMigrationTests {
  func migrated(_ file: URL) throws {
    try RawDatabase.open(file.path) { db in
      try Migration001.apply(db)
      try db.execute(sql: """
      INSERT INTO accounts (id, kind, name, created_at) VALUES
        ('person', 'human', 'Person', '2026-01-01T00:00:00Z'),
        ('other', 'human', 'Other', '2026-01-01T00:00:00Z'),
        ('removed', 'human', 'Removed', '2026-01-01T00:00:00Z'),
        ('machine', 'machine', 'Box', '2026-01-01T00:00:00Z');
      UPDATE accounts SET removed_at = '2026-02-01T00:00:00Z' WHERE id = 'removed';
      INSERT INTO groups (id, created_at) VALUES
        ('personal', '2026-01-01T00:00:00Z'), ('team', '2026-01-02T00:00:00Z'),
        ('ops', '2026-01-03T00:00:00Z');
      INSERT INTO group_members VALUES
        ('personal', 'person', '2026-01-01T00:00:00Z'),
        ('team', 'person', '2026-01-02T00:00:00Z'),
        ('team', 'removed', '2026-01-02T00:00:00Z'),
        ('ops', 'other', '2026-01-03T00:00:00Z'),
        ('ops', 'person', '2026-01-03T00:00:00Z');
      INSERT INTO group_edges VALUES
        ('personal', 'personal', 'admin', '2026-01-01T00:00:00Z', NULL),
        ('team', 'team', 'admin', '2026-01-02T00:00:00Z', NULL),
        ('team', 'shared', 'admin', '2026-01-02T00:00:00Z', NULL),
        ('ops', 'ops', 'admin', '2026-01-03T00:00:00Z', NULL),
        ('team', 'ops', 'read', '2026-01-02T00:00:00Z', NULL),
        ('personal', 'ops', 'read', '2026-01-01T00:00:00Z', NULL);
      INSERT INTO machines (id, account_id, name, created_at, grp) VALUES ('mc_box', 'machine', 'box', '2026-01-01T00:00:00Z', 'shared');
      """)
      try Migration003.apply(db)
      try Migration004.apply(db)
      // A space that opens this file finds every migration applied.
      try db.execute(sql: """
      CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
      INSERT INTO grdb_migrations VALUES ('001'), ('002'), ('003'), ('004');
      """)
    }
  }

  @Test func theReachOfEveryGroupBecomesItsListAndRole() async throws {
    let folder = try ScratchFolder("access-migration")
    let file = folder.url.appending(path: "space.sqlite")
    try migrated(file)
    let database = try RawDatabase(path: file.path)
    let rows = try database.access { db in
      try db.rows(
        """
        SELECT CASE WHEN account_id IS NULL THEN 'group ' || source_group ELSE 'account ' || account_id END AS subject,
          grp, role FROM group_roles ORDER BY subject
        """,
      ).map { row in ([row["subject"], row["grp"], row["role"]] as [String?]).map { $0 ?? "?" }.joined(separator: " ") }
    }
    #expect(Set(rows) == [
      "account other ops admin",
      "account person ops admin",
      "account person personal admin",
      "account person settings admin",
      "account person team admin",
      "group personal ops write",
      "group team ops write",
    ])
    // A removed account keeps no membership.
    #expect(!rows.contains { $0.contains("removed") })
  }

  @Test func sharedOpensTheSettingsGroupStaysReadableAndNoEdgesRemain() async throws {
    let folder = try ScratchFolder("access-migration")
    let file = folder.url.appending(path: "space.sqlite")
    try migrated(file)
    let database = try RawDatabase(path: file.path)
    let facts = try database.access { db in
      (
        visibility: try db.strings("SELECT id || ' ' || visibility FROM groups ORDER BY id"),
        secrets: try db.string("SELECT secrets_scope FROM groups WHERE id = 'shared'"),
        scope: try db.string("SELECT scope FROM machines WHERE id = 'mc_box'"),
        tables: try ["group_edges", "group_reads", "group_members"].filter { try db.tableExists($0) },
        guest: try db.int("SELECT guest FROM accounts WHERE id = 'person'"),
      )
    }
    #expect(facts.visibility == ["ops private", "personal private", "settings private", "shared open", "team private"])
    #expect(facts.secrets == "owner")
    #expect(facts.scope == "reachable")
    #expect(facts.tables == [])
    #expect(facts.guest == 0)

    let space = registerSessionExecution(try Space.open(file: file))
    let team = GroupID(rawValue: "team")
    let person = AccountID(rawValue: "person")
    #expect(try await space.reads(team) == [team, GroupID(rawValue: "ops"), .settings, .shared])
    let session = try await space.sessions.createSession(group: team, title: "s", kind: .agent, createdBy: "owner", model: .test)
    #expect(try await space.role(of: .session(session), in: GroupID(rawValue: "ops"), acting: team) == .write)
    #expect(try await space.isHumanAdmin(person, of: GroupID(rawValue: "settings")))
    #expect(try await space.group(GroupID(rawValue: "personal")) == nil)
  }
}
