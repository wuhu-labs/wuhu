import GRDB

enum Migration032 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: "DROP TABLE session_commands")
  }
}
