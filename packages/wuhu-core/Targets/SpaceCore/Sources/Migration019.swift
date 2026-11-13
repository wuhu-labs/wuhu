enum Migration019 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    ALTER TABLE session_queue ADD COLUMN topic TEXT;
    ALTER TABLE session_queue ADD COLUMN due_at TEXT;
    """)
  }
}
