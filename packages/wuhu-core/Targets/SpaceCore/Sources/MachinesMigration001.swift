/// Each machine's row takes its account's newest live exec-machine key and newest unexpired join token; then the
/// machine accounts go, with everything the person cell and Wuwei kept for them.
enum MachinesMigration001 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    PRAGMA defer_foreign_keys = ON;
    CREATE TEMP TABLE machine_accounts AS SELECT id FROM accounts WHERE kind = 'machine';
    CREATE TEMP TABLE machines_keyed AS
    SELECT m.id, m.created_at, m.grp, m.scope, k.pubkey, k.created_at AS enrolled_at, k.created_by AS enrolled_by,
      t.token_hash, t.expires_at AS token_expires_at
    FROM machines m
    LEFT JOIN account_keys k ON k.pubkey = (
      SELECT pubkey FROM account_keys
      WHERE account_id = m.account_id AND (' ' || capabilities || ' ') LIKE '% exec-machine %'
        AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      ORDER BY created_at DESC, pubkey LIMIT 1
    )
    LEFT JOIN join_tokens t ON t.token_hash = (
      SELECT token_hash FROM join_tokens
      WHERE account_id = m.account_id AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      ORDER BY expires_at DESC, token_hash LIMIT 1
    );
    DROP TABLE machines;
    CREATE TABLE machines (
      id TEXT NOT NULL PRIMARY KEY,
      created_at TEXT NOT NULL,
      grp TEXT NOT NULL DEFAULT '',
      scope TEXT NOT NULL DEFAULT 'owner' CHECK (scope IN ('owner', 'reachable')),
      pubkey TEXT,
      enrolled_at TEXT,
      enrolled_by TEXT,
      token_hash TEXT,
      token_expires_at TEXT,
      CHECK ((pubkey IS NULL) = (enrolled_at IS NULL)),
      CHECK ((token_hash IS NULL) = (token_expires_at IS NULL))
    );
    INSERT INTO machines SELECT id, created_at, grp, scope, pubkey, enrolled_at, enrolled_by, token_hash, token_expires_at FROM machines_keyed;
    DROP TABLE machines_keyed;
    CREATE UNIQUE INDEX machines_by_pubkey ON machines (pubkey);
    CREATE UNIQUE INDEX machines_by_token ON machines (token_hash);
    CREATE TRIGGER "machines_grp_required" BEFORE INSERT ON "machines" WHEN NEW."grp" = ''
      BEGIN SELECT RAISE(ABORT, 'grp required: machines'); END;
    DROP TABLE join_token_receipts;
    DELETE FROM web_push_subscriptions WHERE owner_account IN (SELECT id FROM machine_accounts);
    DELETE FROM push_relay_grants WHERE owner_account IN (SELECT id FROM machine_accounts);
    DELETE FROM notifications WHERE owner_account IN (SELECT id FROM machine_accounts);
    DELETE FROM watermarks WHERE owner_account IN (SELECT id FROM machine_accounts);
    DELETE FROM user_profiles WHERE owner_account IN (SELECT id FROM machine_accounts);
    DELETE FROM person_hidden_sidebars WHERE owner_account IN (SELECT id FROM machine_accounts);
    DELETE FROM read_sessions WHERE account_id IN (SELECT id FROM machine_accounts);
    DELETE FROM join_tokens WHERE account_id IN (SELECT id FROM machine_accounts);
    UPDATE join_tokens SET created_by = NULL WHERE created_by IN (SELECT id FROM machine_accounts);
    UPDATE account_keys SET created_by = NULL WHERE created_by IN (SELECT id FROM machine_accounts);
    DELETE FROM account_keys WHERE account_id IN (SELECT id FROM machine_accounts);
    DELETE FROM device_commands WHERE device_id IN (SELECT id FROM devices WHERE account_id IN (SELECT id FROM machine_accounts));
    DELETE FROM message_devices WHERE device_id IN (SELECT id FROM devices WHERE account_id IN (SELECT id FROM machine_accounts));
    DELETE FROM devices WHERE account_id IN (SELECT id FROM machine_accounts);
    DELETE FROM personas WHERE account_id IN (SELECT id FROM machine_accounts);
    DELETE FROM group_roles WHERE account_id IN (SELECT id FROM machine_accounts);
    DELETE FROM accounts WHERE id IN (SELECT id FROM machine_accounts);
    DELETE FROM wuwei_mail WHERE recipient IN (SELECT 'PersonCell/' || id FROM machine_accounts)
      OR (recipient LIKE 'PersonCell/%' AND CAST(payload AS TEXT) LIKE '{"machineAccount":%')
      OR (recipient LIKE 'MachineCell/%' AND (CAST(payload AS TEXT) LIKE '{"create":%' OR CAST(payload AS TEXT) LIKE '{"closeBoxes":%'));
    DELETE FROM wuwei_addressable WHERE address IN (SELECT 'PersonCell/' || id FROM machine_accounts);
    DELETE FROM aliases WHERE kind = 'machine' AND target NOT IN (SELECT id FROM machines);
    DROP TABLE machine_accounts;
    """)
  }
}
