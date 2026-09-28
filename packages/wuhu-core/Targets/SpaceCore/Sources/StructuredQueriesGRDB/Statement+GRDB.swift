// Adapted from pointfreeco/sqlite-data (MIT License). See SQLiteQueryDecoder.swift.
import GRDB
import StructuredQueriesCore

extension StructuredQueriesCore.Statement {
  func execute(_ db: Database) throws where QueryValue == () {
    try QueryVoidCursor(db: db, query: query).next()
  }

  func fetchAll(_ db: Database) throws -> [QueryValue.QueryOutput]
    where QueryValue: QueryRepresentable
  {
    let cursor = try QueryValueCursor<QueryValue>(db: db, query: query)
    var output: [QueryValue.QueryOutput] = []
    try cursor.forEach { output.append($0) }
    return output
  }

  func fetchOne(_ db: Database) throws -> QueryValue.QueryOutput?
    where QueryValue: QueryRepresentable
  {
    try QueryValueCursor<QueryValue>(db: db, query: query).next()
  }
}

extension SelectStatement where QueryValue == (), Joins == () {
  func fetchCount(_ db: Database) throws -> Int {
    try asSelect().count().fetchOne(db) ?? 0
  }

  func fetchAll(_ db: Database) throws -> [From.QueryOutput] {
    let cursor = try QueryValueCursor<From>(db: db, query: query)
    var output: [From.QueryOutput] = []
    try cursor.forEach { output.append($0) }
    return output
  }

  func fetchOne(_ db: Database) throws -> From.QueryOutput? {
    try QueryValueCursor<From>(db: db, query: asSelect().limit(1).query).next()
  }
}
