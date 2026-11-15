enum Migration056 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE INDEX IF NOT EXISTS wuwei_addressable_draining ON wuwei_addressable (expires_at) WHERE draining = 1;
    CREATE TABLE IF NOT EXISTS wuwei_successor (id INTEGER PRIMARY KEY CHECK (id = 1), worker TEXT NOT NULL, announced_at INTEGER NOT NULL);
    """)
  }
}
