import Foundation
import GRDB
import SessionDomain

let sessionCommandSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_commands" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "kind" TEXT NOT NULL,
  "instructions" TEXT,
  "created_at" TEXT NOT NULL
);
"""

public enum SessionCommand: Hashable, Sendable {
  case compact(instructions: String?)

  var kind: String {
    switch self {
    case .compact: "compact"
    }
  }

  var instructions: String? {
    switch self {
    case let .compact(instructions): instructions
    }
  }

  init?(kind: String, instructions: String?) {
    switch kind {
    case "compact": self = .compact(instructions: instructions)
    default: return nil
    }
  }
}

extension SessionStore {
  // One standing command per session: a second request before the daemon
  // takes delivery replaces the first rather than queueing behind it.
  public func requestCommand(_ id: SessionID, _ command: SessionCommand) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try db.execute(
        sql: """
        INSERT INTO session_commands (session_id, kind, instructions, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
          kind = excluded.kind, instructions = excluded.instructions, created_at = excluded.created_at
        """,
        arguments: [key, command.kind, command.instructions, now],
      )
    }
    signals.post(id)
  }

  public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.pendingCommand(key, in: db)
    }
  }

  public func takeCommand(_ id: SessionID) async throws -> SessionCommand? {
    let key = id.rawValue
    return try await writer.write { db in
      guard let row = try Row.fetchOne(
        db, sql: "SELECT kind, instructions FROM session_commands WHERE session_id = ?", arguments: [key],
      ) else { return nil }
      try db.execute(sql: "DELETE FROM session_commands WHERE session_id = ?", arguments: [key])
      return SessionCommand(kind: row["kind"], instructions: row["instructions"])
    }
  }
}

extension Sessions {
  static func pendingCommand(_ key: String, in db: Database) throws -> SessionCommand? {
    guard let row = try Row.fetchOne(
      db, sql: "SELECT kind, instructions FROM session_commands WHERE session_id = ?", arguments: [key],
    ) else { return nil }
    return SessionCommand(kind: row["kind"], instructions: row["instructions"])
  }
}
