enum Migration020 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    ALTER TABLE requests ADD COLUMN stall_seconds REAL;
    DELETE FROM subscription_slots WHERE subscription_id LIKE 'stall.%';
    UPDATE requests SET status = 'open' WHERE status = 'stalled';
    """)
  }
}
