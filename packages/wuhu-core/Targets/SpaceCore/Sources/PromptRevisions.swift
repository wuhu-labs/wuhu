import GRDB
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

// The space revision a session's prompt renders at. The space parts
// of the prompt (space and home AGENTS.md, space and home skills) are read as
// of this revision, so an edit reaches a live session only when the number
// moves: at creation, after a template clone, at every compaction and at
// Start over. A session with no row predates the table: it renders from the
// latest revision and gets its row at its next activation.
let sessionPromptRevisionSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_prompt_revisions" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "rev" INTEGER NOT NULL
);
"""

@Table("session_prompt_revisions")
struct SessionPromptRevisionRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("rev") var rev: Int64
}

enum PromptRevisions {
  @discardableResult
  static func advance(_ key: String, in db: Database) throws -> Int {
    let rev = try Substrate.maxRevision(in: db)
    try SessionPromptRevisionRow.upsert { SessionPromptRevisionRow(sessionID: key, rev: rev) }.execute(db)
    try db.execute(
      sql: """
      INSERT INTO session_space_layer (session_id, space_layer)
      SELECT s.id, COALESCE(g.space_layer, 1) FROM sessions s LEFT JOIN groups g ON g.id = s.grp WHERE s.id = ?
      ON CONFLICT (session_id) DO UPDATE SET space_layer = excluded.space_layer
      """,
      arguments: [key],
    )
    return Int(rev)
  }

  /// Whether the frozen prompt carries the space-wide layer; nil before the
  /// session's first revision.
  static func spaceLayer(_ key: String, in db: Database) throws -> Bool? {
    try Bool.fetchOne(db, sql: "SELECT space_layer FROM session_space_layer WHERE session_id = ?", arguments: [key])
  }

  static func stored(_ key: String, in db: Database) throws -> Int? {
    try SessionPromptRevisionRow.where { $0.sessionID.eq(key) }.fetchOne(db).map { Int($0.rev) }
  }
}

extension SessionStore {
  /// The revision the session's prompt renders at, or nil for a session that
  /// predates the table and has not been activated since.
  public func promptRevision(_ id: SessionID) async throws -> Int? {
    let key = id.rawValue
    return try await writer.read { db in
      _ = try Sessions.record(key, in: db)
      return try PromptRevisions.stored(key, in: db)
    }
  }

  /// Whether the frozen prompt carries the space-wide layer, or nil when the
  /// session has no prompt revision yet.
  public func promptSpaceLayer(_ id: SessionID) async throws -> Bool? {
    let key = id.rawValue
    return try await writer.read { db in try PromptRevisions.spaceLayer(key, in: db) }
  }

  /// Returns the stored prompt revision,
  /// or the current one, stored, when there is none yet.
  public func activatePromptRevision(_ id: SessionID) async throws -> Int {
    // Every kernel inference lands here: a stored row is a plain read, and a
    // write transaction opens only for a session that has none yet.
    if let stored = try await promptRevision(id) { return stored }
    let key = id.rawValue
    return try await writer.write { db in
      try PromptRevisions.stored(key, in: db) ?? PromptRevisions.advance(key, in: db)
    }
  }

  func advancePromptRevision(_ id: SessionID) async throws {
    let key = id.rawValue
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try PromptRevisions.advance(key, in: db)
    }
  }
}
