// A handler slot is an observer cell's state: the input no firing has taken
// yet waits on the slot, and the firing in progress is the cell's.
enum Migration024 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    ALTER TABLE subscription_slots ADD COLUMN pending TEXT;
    ALTER TABLE subscription_slots ADD COLUMN pending_marker TEXT;
    DELETE FROM subscription_slots WHERE json_type(payload, '$.handlerFiring.retiring') IS NOT NULL;
    UPDATE subscription_slots SET payload = json_remove(payload, '$.handlerFiring', '$.handlerFailed');
    UPDATE subscription_firings SET outcome = 'cancelled' WHERE outcome IN ('running', 'interrupted');
    """)
  }
}
