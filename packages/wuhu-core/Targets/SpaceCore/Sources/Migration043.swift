import GRDB

/// A group's current alias lives in the `aliases` namespace alone, where the space cell writes it; the triggers
/// that copied `groups.alias` into it go with the column.
enum Migration043 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    DROP TRIGGER IF EXISTS groups_alias_insert;
    DROP TRIGGER IF EXISTS groups_alias_update;
    ALTER TABLE aliases ADD COLUMN current INTEGER NOT NULL DEFAULT 0;
    INSERT OR IGNORE INTO aliases (name, kind, target)
    SELECT lower(alias), 'group', id FROM groups WHERE alias IS NOT NULL;
    UPDATE aliases SET current = 1
    WHERE kind = 'group'
      AND EXISTS (SELECT 1 FROM groups WHERE groups.id = aliases.target AND groups.alias = aliases.name COLLATE NOCASE);
    ALTER TABLE groups DROP COLUMN alias;
    """)
  }
}
