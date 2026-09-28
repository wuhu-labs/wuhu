import Foundation
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

let sessionContextSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_context" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "used_tokens" INTEGER NOT NULL,
  "max_tokens" INTEGER NOT NULL,
  "reported_at" TEXT NOT NULL
);
"""

@Table("session_context")
struct SessionContextRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("used_tokens") var usedTokens: Int64
  @Column("max_tokens") var maxTokens: Int64
  @Column("reported_at") var reportedAt: String
}

public struct SessionContextReport: Hashable, Sendable {
  public var usedTokens: Int
  public var maxTokens: Int
  public var reportedAt: Date

  public init(usedTokens: Int, maxTokens: Int, reportedAt: Date) {
    self.usedTokens = usedTokens
    self.maxTokens = maxTokens
    self.reportedAt = reportedAt
  }
}

extension SessionStore {
  // The executor's own accounting, latest wins. Only executors that report it
  // have a row; a kernel session's context is estimated from its transcript.
  public func recordContext(_ id: SessionID, usedTokens: Int, maxTokens: Int) async throws {
    let row = SessionContextRow(
      sessionID: id.rawValue,
      usedTokens: Int64(usedTokens),
      maxTokens: Int64(maxTokens),
      reportedAt: SQLiteDateFormat.string(from: dateGen.now),
    )
    try await writer.write { db in
      try SessionContextRow.upsert { row }.execute(db)
    }
  }

  public func context(_ id: SessionID) async throws -> SessionContextReport? {
    let key = id.rawValue
    return try await writer.read { db in
      guard let row = try SessionContextRow.where({ $0.sessionID.eq(key) }).fetchOne(db) else {
        return nil
      }
      return SessionContextReport(
        usedTokens: Int(row.usedTokens),
        maxTokens: Int(row.maxTokens),
        reportedAt: try SQLiteDateFormat.date(from: row.reportedAt),
      )
    }
  }
}
