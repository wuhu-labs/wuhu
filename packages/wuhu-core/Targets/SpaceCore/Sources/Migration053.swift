enum Migration053 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "ALTER TABLE wuwei_addressable ADD COLUMN draining INTEGER NOT NULL DEFAULT 0")
  }
}
