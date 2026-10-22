import GRDB

enum Migration005 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: "DROP TABLE session_blobs")
  }
}
