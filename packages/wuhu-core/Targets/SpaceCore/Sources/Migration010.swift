import GRDB

enum Migration010 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS machine_v2_trace_retention ON machine_v2_trace(grp, start_at);")
  }
}
