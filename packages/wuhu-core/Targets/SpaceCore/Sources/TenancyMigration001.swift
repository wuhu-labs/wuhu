enum TenancyMigration001 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "ALTER TABLE allocations DROP COLUMN created_at")
  }
}
