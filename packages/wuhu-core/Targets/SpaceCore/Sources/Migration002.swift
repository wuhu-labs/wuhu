import GRDB

enum Migration002 {
  static func apply(_ db: Database) throws {
    // The removed executors' tables go before the accounts: `contractors`
    // names an account without a cascade, so an account delete behind a table
    // that still holds rows would fail the foreign-key check.
    for table in legacyTables {
      try db.execute(sql: "DROP TABLE IF EXISTS \"\(table)\"")
    }
    try db.execute(sql: "DELETE FROM session_subscriptions WHERE subscription_id LIKE 'park.%'")
    try deleteContractorAccounts(db)
  }

  /// A contractor account was a credential for a wrapper process: it owned keys and group membership and nothing else. Every row that names it goes first, so the delete does not lean on cascades an old database may not have.
  private static func deleteContractorAccounts(_ db: Database) throws {
    let contractors = "SELECT id FROM accounts WHERE kind = 'contractor'"
    let contractorKeys = "SELECT pubkey FROM account_keys WHERE account_id IN (\(contractors)) OR (' ' || capabilities || ' ') LIKE '% contractor %'"
    let contractorDevices = "SELECT id FROM devices WHERE account_id IN (\(contractors))"
    try db.execute(sql: "DELETE FROM device_commands WHERE device_id IN (\(contractorDevices))")
    try db.execute(sql: "DELETE FROM message_devices WHERE device_id IN (\(contractorDevices))")
    try db.execute(sql: "DELETE FROM devices WHERE account_id IN (\(contractors))")
    try db.execute(sql: "DELETE FROM read_sessions WHERE account_id IN (\(contractors))")
    try db.execute(sql: "DELETE FROM group_members WHERE account_id IN (\(contractors))")
    try db.execute(sql: "DELETE FROM personas WHERE account_id IN (\(contractors))")
    try db.execute(sql: "DELETE FROM join_tokens WHERE account_id IN (\(contractors))")
    try db.execute(sql: "UPDATE account_keys SET created_by = NULL WHERE created_by IN (\(contractors))")
    try db.execute(sql: "UPDATE join_tokens SET created_by = NULL WHERE created_by IN (\(contractors))")
    // The `contractor` key capability no longer decodes, so a key carrying it outlives its vocabulary.
    try db.execute(sql: "DELETE FROM account_keys WHERE pubkey IN (\(contractorKeys))")
    try db.execute(sql: "DELETE FROM accounts WHERE kind = 'contractor'")
  }

  /// The removed executors' stores and the stores that predate the current schema, children before the tables they name. Their indexes drop with them.
  private static let legacyTables = [
    "claude_code_handovers",
    "claude_code_sessions",
    "claude_history_calls",
    "claude_history_items",
    "claude_history_progress",
    "claude_history_seen",
    "contractor_entries",
    "contractor_rate_limits",
    "contractor_slots",
    "contractors",
    "exec_jobs",
    "physical_sessions",
    "session_mirror",
    "session_scope_context",
    "session_watches",
  ]
}
