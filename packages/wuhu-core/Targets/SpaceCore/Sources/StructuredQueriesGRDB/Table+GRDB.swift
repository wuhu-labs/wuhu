// Adapted from pointfreeco/sqlite-data (MIT License). See SQLiteQueryDecoder.swift.
import GRDB
import StructuredQueriesCore

extension StructuredQueriesCore.Table {
  static func fetchAll(_ db: Database) throws -> [QueryOutput] {
    try all.fetchAll(db)
  }

  static func fetchOne(_ db: Database) throws -> QueryOutput? {
    try all.fetchOne(db)
  }

  static func fetchCount(_ db: Database) throws -> Int {
    try all.fetchCount(db)
  }
}
