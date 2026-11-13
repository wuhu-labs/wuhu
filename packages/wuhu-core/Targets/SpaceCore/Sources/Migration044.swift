import GRDB

enum Migration044 {
  static func apply(_ db: Database) throws {
    for (table, principal) in [("notifications", "recipient"), ("watermarks", "identity"), ("user_profiles", "principal"), ("web_push_subscriptions", "recipient"), ("push_relay_grants", "recipient")] {
      try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN owner_account TEXT NOT NULL DEFAULT ''")
      try db.execute(sql: "UPDATE \(table) SET owner_account = COALESCE((SELECT account_id FROM personas WHERE name = \(table).\(principal)), \(principal))")
    }
    try db.execute(sql: "ALTER TABLE device_commands ADD COLUMN owner_account TEXT NOT NULL DEFAULT ''")
    try db.execute(sql: "UPDATE device_commands SET owner_account = (SELECT account_id FROM devices WHERE id = device_commands.device_id)")
    try db.execute(sql: """
    CREATE INDEX notifications_by_owner ON notifications (owner_account, n);
    DROP TRIGGER user_profiles_alias_insert;
    DROP TRIGGER user_profiles_alias_update;
    INSERT OR IGNORE INTO aliases (name, kind, target)
    SELECT lower(handle), 'person', principal FROM user_profiles;
    UPDATE aliases SET current = 1
    WHERE kind = 'person'
      AND EXISTS (SELECT 1 FROM user_profiles WHERE user_profiles.principal = aliases.target AND user_profiles.handle = aliases.name COLLATE NOCASE);
    CREATE TABLE user_profiles_person (
      principal TEXT NOT NULL PRIMARY KEY,
      display_name TEXT,
      owner_account TEXT NOT NULL
    );
    INSERT INTO user_profiles_person SELECT principal, display_name, owner_account FROM user_profiles;
    DROP TABLE user_profiles;
    ALTER TABLE user_profiles_person RENAME TO user_profiles;
    """)
  }
}
