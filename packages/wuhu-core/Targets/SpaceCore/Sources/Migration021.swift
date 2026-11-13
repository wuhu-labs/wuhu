enum Migration021 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DELETE FROM subscription_slots WHERE subscription_id LIKE 'deadline.%';
    UPDATE requests SET status = 'open' WHERE status = 'overdue';
    ALTER TABLE requests DROP COLUMN deadline_at;
    """)
  }
}
