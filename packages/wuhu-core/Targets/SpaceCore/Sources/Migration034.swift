enum Migration034 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "DROP TABLE session_cache_warming")
  }
}
