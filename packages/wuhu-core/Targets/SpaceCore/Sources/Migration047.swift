import GRDB

enum Migration047 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE user_profiles ADD COLUMN avatar TEXT;
    CREATE TABLE person_hidden_sidebars (
      owner_account TEXT NOT NULL,
      grp TEXT NOT NULL,
      path TEXT NOT NULL,
      PRIMARY KEY (owner_account, grp, path)
    ) WITHOUT ROWID;

    WITH principals(principal, owner_account) AS (
      SELECT name, account_id FROM personas
      UNION
      SELECT principal, owner_account FROM user_profiles
    )
    INSERT INTO user_profiles (principal, display_name, owner_account, avatar)
    SELECT p.principal, NULL, p.owner_account, h.blob_hash
    FROM principals p
    JOIN fs_heads h ON h.grp = 'shared' AND h.kind = 'file'
      AND h.path = '/users/' || p.principal || '/avatar.png'
    ON CONFLICT(principal) DO UPDATE SET avatar = excluded.avatar;

    WITH entries AS (
      SELECT g.personal_account AS owner_account,
        CASE WHEN e.type = 'object' THEN e.value ELSE '{}' END AS entry
      FROM groups g
      JOIN fs_heads h ON h.grp = g.id AND h.kind = 'file'
        AND h.path = '/.settings/sidebars.json'
      JOIN bucket_objects b ON b.hash = h.blob_hash AND b.content IS NOT NULL
      JOIN json_each(CASE WHEN json_valid(CAST(b.content AS TEXT)) THEN
        CASE WHEN json_type(CAST(b.content AS TEXT)) = 'object'
          AND json_type(CAST(b.content AS TEXT), '$.hidden') = 'array'
          THEN json_extract(CAST(b.content AS TEXT), '$.hidden') ELSE '[]' END
        ELSE '[]' END) e
      WHERE g.personal_account IS NOT NULL
    )
    INSERT INTO person_hidden_sidebars (owner_account, grp, path)
    SELECT DISTINCT owner_account,
      json_extract(entry, '$.group'), json_extract(entry, '$.path')
    FROM entries
    WHERE json_type(entry, '$.group') = 'text'
      AND json_type(entry, '$.path') = 'text';

    CREATE TEMP TABLE personal_groups047 AS
    SELECT g.id, g.personal_account AS account_id, g.created_at,
      EXISTS (SELECT 1 FROM fs_versions v WHERE v.grp = g.id
        AND v.kind IS NOT 'directory' AND v.path <> '/.settings/sidebars.json')
      OR EXISTS (SELECT 1 FROM tables t WHERE t.grp = g.id)
      OR EXISTS (SELECT 1 FROM sessions s WHERE s.grp = g.id)
      OR EXISTS (SELECT 1 FROM conversations c WHERE c.grp = g.id)
      OR EXISTS (SELECT 1 FROM machines m WHERE m.grp = g.id)
      OR EXISTS (SELECT 1 FROM subscription_slots s
        WHERE s.owner_kind = 'group' AND s.owner = g.id) AS retained
    FROM groups g WHERE g.personal_account IS NOT NULL;

    UPDATE groups SET name = id, visibility = 'private', personal_account = NULL
    WHERE id IN (SELECT id FROM personal_groups047 WHERE retained);
    INSERT INTO group_roles (account_id, grp, role, created_at)
    SELECT account_id, id, 'admin', created_at FROM personal_groups047 WHERE retained
    ON CONFLICT(account_id, grp) WHERE account_id IS NOT NULL
    DO UPDATE SET role = 'admin';

    DELETE FROM group_roles
    WHERE grp IN (SELECT id FROM personal_groups047 WHERE NOT retained)
      OR source_group IN (SELECT id FROM personal_groups047 WHERE NOT retained);
    """)
    for table in ["fs_heads", "fs_versions", "docs", "doc_custom_attrs", "links", "revision_actors", "revisions", "read_sessions", "join_tokens"] {
      try db.execute(sql: "DELETE FROM \(table) WHERE grp IN (SELECT id FROM personal_groups047 WHERE NOT retained)")
    }
    try db.execute(sql: """
    DELETE FROM groups WHERE id IN (SELECT id FROM personal_groups047 WHERE NOT retained);
    DROP INDEX groups_personal_account;
    ALTER TABLE groups DROP COLUMN personal_account;
    DROP TABLE personal_groups047;
    """)
  }
}
