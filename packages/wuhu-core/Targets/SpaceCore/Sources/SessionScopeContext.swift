#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

let sessionScopeContextSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_scope_context" (
  "session_id" TEXT NOT NULL,
  "tool_call_id" TEXT NOT NULL,
  "folders" TEXT NOT NULL,
  "text" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "tool_call_id")
);
"""

@Table("session_scope_context")
struct SessionScopeContextRow {
  @Column("session_id") var sessionID: String
  @Column("tool_call_id") var toolCallID: String
  @Column("folders") var folders: String
  @Column("text") var text: String
}

extension SessionStore {
  public func recordScopeContext(_ id: SessionID, toolCallID: ToolCallID, context: ScopeContext) async throws {
    let row = SessionScopeContextRow(
      sessionID: id.rawValue,
      toolCallID: toolCallID.rawValue,
      folders: try Sessions.encode(context.folders),
      text: context.text,
    )
    try await writer.write { db in
      try SessionScopeContextRow.insert { row } onConflict: {
        ($0.sessionID, $0.toolCallID)
      } doUpdate: {
        $0.folders = $1.folders
        $0.text = $1.text
      }
      .execute(db)
    }
  }

  public func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext? {
    let key = id.rawValue
    let callID = toolCallID.rawValue
    return try await writer.read { db in
      guard let row = try SessionScopeContextRow
        .where({ $0.sessionID.eq(key) && $0.toolCallID.eq(callID) })
        .fetchOne(db)
      else { return nil }
      return ScopeContext(folders: try Sessions.decode([String: String?].self, from: row.folders), text: row.text)
    }
  }
}
