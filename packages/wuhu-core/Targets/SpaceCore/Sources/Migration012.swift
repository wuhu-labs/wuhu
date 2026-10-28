import GRDB

enum Migration012 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TEMP TABLE removed_machines AS
      SELECT id, account_id FROM machines
      WHERE NOT EXISTS (SELECT 1 FROM machine_v2_members WHERE machine_id = machines.id);
    DELETE FROM script_execs WHERE exec_id IN (
      SELECT id FROM machine_execs WHERE machine_id IN (SELECT id FROM removed_machines)
    );
    DELETE FROM machine_execs WHERE machine_id IN (SELECT id FROM removed_machines);
    UPDATE devices SET machine_id = NULL WHERE machine_id IN (SELECT id FROM removed_machines);
    DELETE FROM aliases WHERE kind = 'machine' AND target IN (SELECT id FROM removed_machines);
    DELETE FROM group_roles WHERE account_id IN (SELECT account_id FROM removed_machines);
    DELETE FROM read_sessions WHERE account_id IN (SELECT account_id FROM removed_machines);
    DELETE FROM join_token_receipts WHERE pubkey IN (
      SELECT pubkey FROM account_keys WHERE account_id IN (SELECT account_id FROM removed_machines)
    );
    DELETE FROM join_tokens WHERE account_id IN (SELECT account_id FROM removed_machines);
    UPDATE join_tokens SET created_by = NULL WHERE created_by IN (SELECT account_id FROM removed_machines);
    UPDATE account_keys SET created_by = NULL WHERE created_by IN (SELECT account_id FROM removed_machines);
    DELETE FROM account_keys WHERE account_id IN (SELECT account_id FROM removed_machines);
    DELETE FROM device_commands WHERE device_id IN (
      SELECT id FROM devices WHERE account_id IN (SELECT account_id FROM removed_machines)
    );
    DELETE FROM message_devices WHERE device_id IN (
      SELECT id FROM devices WHERE account_id IN (SELECT account_id FROM removed_machines)
    );
    DELETE FROM devices WHERE account_id IN (SELECT account_id FROM removed_machines);
    DELETE FROM personas WHERE account_id IN (SELECT account_id FROM removed_machines);
    UPDATE groups SET personal_account = NULL WHERE personal_account IN (SELECT account_id FROM removed_machines);
    DELETE FROM machines WHERE id IN (SELECT id FROM removed_machines);
    DELETE FROM accounts WHERE id IN (SELECT account_id FROM removed_machines);
    DROP TABLE removed_machines;
    """)
  }
}
