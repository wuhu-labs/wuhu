import GRDB

// A session's requests as sent, one row per message, addressed by generation
// and position; position 0 is the system prompt and tool list. Rows are only
// ever inserted.
enum Migration026 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE session_lines (
      session_id TEXT NOT NULL,
      generation INTEGER NOT NULL,
      position INTEGER NOT NULL,
      at TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool_result')),
      key TEXT NOT NULL,
      message TEXT NOT NULL,
      meta TEXT,
      PRIMARY KEY (session_id, generation, position)
    ) WITHOUT ROWID;
    """)
  }
}
