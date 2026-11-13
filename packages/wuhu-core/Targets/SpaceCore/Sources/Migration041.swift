import GRDB

enum Migration041 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE machine_presence ADD COLUMN filePieceBytes INTEGER;")
    try db.execute(sql: "ALTER TABLE machine_file_operations ADD COLUMN outputChannels TEXT NOT NULL DEFAULT '[]';")
  }
}
