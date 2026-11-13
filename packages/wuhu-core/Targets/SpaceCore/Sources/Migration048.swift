/// A machine's name lives in the `aliases` namespace alone, where the space cell writes it, and an account's rows
/// name their owner so the machine paths can stop writing them on the host's writer.
enum Migration048 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DROP TRIGGER IF EXISTS machines_alias_insert;
    DROP TRIGGER IF EXISTS machines_alias_update;
    INSERT OR IGNORE INTO aliases (name, kind, target)
    SELECT lower(name), 'machine', id FROM machines WHERE name IS NOT NULL;
    UPDATE aliases SET current = 1
    WHERE kind = 'machine'
      AND EXISTS (SELECT 1 FROM machines WHERE machines.id = aliases.target AND machines.name = aliases.name COLLATE NOCASE);
    ALTER TABLE machines DROP COLUMN name;
    UPDATE accounts SET name = NULL WHERE kind = 'machine';
    """)
    for (table, owner) in [
      ("accounts", "id"),
      ("account_keys", "account_id"),
      ("join_tokens", "account_id"),
      ("read_sessions", "account_id"),
      ("personas", "account_id"),
      ("devices", "account_id"),
    ] {
      try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN owner TEXT NOT NULL DEFAULT ''")
      try db.execute(sql: "UPDATE \(table) SET owner = \(owner)")
    }
    try db.execute(sql: """
    ALTER TABLE join_token_receipts ADD COLUMN owner TEXT NOT NULL DEFAULT '';
    UPDATE join_token_receipts SET owner = (SELECT account_id FROM account_keys WHERE account_keys.pubkey = join_token_receipts.pubkey);
    """)
  }
}
