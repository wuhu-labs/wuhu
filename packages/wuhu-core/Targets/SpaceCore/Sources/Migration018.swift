import GRDB

enum Migration018 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE session_runtime ADD COLUMN step_try INTEGER NOT NULL DEFAULT 0")
  }
}
