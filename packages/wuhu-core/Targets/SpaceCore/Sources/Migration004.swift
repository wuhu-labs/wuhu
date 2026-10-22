import GRDB

/// Access: open and private groups, the one account/group → group → role table
/// that replaces group edges and the read closure, the secrets and machines
/// switches, and guests. Self-contained by rule: raw SQL and local code.
enum Migration004 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE accounts ADD COLUMN guest INTEGER NOT NULL DEFAULT 0 CHECK (guest IN (0, 1));
    ALTER TABLE groups ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('open', 'private'));
    ALTER TABLE groups ADD COLUMN secrets_scope TEXT NOT NULL DEFAULT 'owner' CHECK (secrets_scope IN ('owner', 'reachable'));
    ALTER TABLE machines ADD COLUMN scope TEXT NOT NULL DEFAULT 'owner' CHECK (scope IN ('owner', 'reachable'));
    """)

    try db.execute(sql: """
    CREATE TABLE group_roles_new (
      account_id TEXT REFERENCES accounts(id),
      source_group TEXT REFERENCES groups(id),
      grp TEXT NOT NULL REFERENCES groups(id),
      role TEXT NOT NULL CHECK (role IN ('read', 'write', 'admin')),
      created_at TEXT NOT NULL,
      CHECK ((account_id IS NULL) != (source_group IS NULL))
    );
    CREATE UNIQUE INDEX group_roles_by_account ON group_roles_new (account_id, grp) WHERE account_id IS NOT NULL;
    CREATE UNIQUE INDEX group_roles_by_source ON group_roles_new (source_group, grp) WHERE source_group IS NOT NULL;
    """)

    // Admins keep administering; every live member keeps the write a
    // membership gave; every pair today's closure reached keeps the write its
    // reach gave ordinary files.
    try db.execute(sql: """
    INSERT INTO group_roles_new (account_id, grp, role, created_at)
      SELECT account_id, grp, role, created_at FROM group_roles
    """)
    try db.execute(sql: """
    INSERT OR IGNORE INTO group_roles_new (account_id, grp, role, created_at)
      SELECT m.account_id, m.grp, 'write', m.joined_at FROM group_members m
      JOIN accounts a ON a.id = m.account_id AND a.removed_at IS NULL
      JOIN groups g ON g.id = m.grp
      WHERE g.personal_account IS NULL OR g.personal_account = m.account_id
    """)
    try db.execute(sql: """
    INSERT OR IGNORE INTO group_roles_new (source_group, grp, role, created_at)
      SELECT r.grp, r.readable, 'write', strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      FROM group_reads r
      JOIN groups s ON s.id = r.grp
      JOIN groups g ON g.id = r.readable
      WHERE r.grp != r.readable AND g.personal_account IS NULL
    """)
    try db.execute(sql: """
    DROP TABLE group_roles;
    ALTER TABLE group_roles_new RENAME TO group_roles;
    DROP TABLE group_members;
    DROP TABLE group_reads;
    DROP TABLE group_edges;
    DROP TABLE group_epoch;
    """)

    // shared becomes an ordinary open group; every machine enrolled before the
    // switch stays usable from every group that writes its owner group.
    try db.execute(sql: "UPDATE groups SET visibility = 'open' WHERE id = 'shared'")
    try db.execute(sql: "UPDATE machines SET scope = 'reachable'")
  }
}
