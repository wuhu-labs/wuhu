enum Migration018 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "ALTER TABLE session_runtime ADD COLUMN step_try INTEGER NOT NULL DEFAULT 0")
  }
}
