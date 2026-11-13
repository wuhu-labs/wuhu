enum Migration051 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "ALTER TABLE session_queue DROP COLUMN drained_at")
  }
}
