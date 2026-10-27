import GRDB
import Logging

// A request moves out of `messages` into its own row. Destructive: the drop of
// `messages.deadline_at` runs only after every request message has exactly one
// row, so a rehearsal on a copy either reports its counts or fails whole.
enum Migration008 {
  struct Backfill: Hashable, Sendable {
    var requestMessages: Int
    var rows: [String: Int]
  }

  struct Unmatched: Error, CustomStringConvertible {
    var requestMessages: Int
    var rows: Int
    var examples: [String]

    var description: String {
      "migration 008: \(requestMessages) request messages but \(rows) request rows; request messages without exactly one row: \(examples.joined(separator: ", "))"
    }
  }

  static func apply(_ db: Database) throws {
    let backfill = try run(db)
    let counts = backfill.rows.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    Logger(label: "wuhu.migration").notice("migration 008: \(backfill.requestMessages) request messages became request rows (\(counts)); messages.deadline_at dropped")
  }

  static func run(_ db: Database) throws -> Backfill {
    try db.execute(sql: """
    CREATE TABLE requests (
      id TEXT PRIMARY KEY,
      grp TEXT NOT NULL,
      requester TEXT NOT NULL,
      task TEXT NOT NULL,
      kind TEXT,
      key TEXT CHECK (key IS NULL OR kind IS NOT NULL),
      status TEXT NOT NULL CHECK (status IN ('open', 'stalled', 'overdue', 'done', 'failed')),
      brief TEXT NOT NULL,
      schema JSON_TEXT,
      fields JSON_TEXT,
      result JSON_TEXT,
      refusals JSON_TEXT NOT NULL DEFAULT '[]',
      deadline_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE UNIQUE INDEX requests_by_key ON requests (grp, kind, key);
    CREATE INDEX requests_by_kind_status ON requests (kind, status);
    CREATE INDEX requests_by_task ON requests (task, status);
    CREATE INDEX requests_by_requester ON requests (requester, status);

    INSERT INTO requests (id, grp, requester, task, status, brief, result, deadline_at, created_at, updated_at)
    SELECT m.request_id, s.grp, m.sender_session_id, t.member,
      CASE
        WHEN f.id IS NOT NULL THEN 'done'
        WHEN ts.id IS NULL OR ts.lifecycle != 'live' THEN 'failed'
        WHEN m.deadline_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now') THEN 'overdue'
        WHEN EXISTS (
          SELECT 1 FROM session_subscriptions ss
          WHERE json_extract(ss.payload, '$.kind.requestStall._0.request') = m.request_id
            AND json_extract(ss.payload, '$.kind.requestStall._0.alerted') = 1
        ) THEN 'stalled'
        ELSE 'open'
      END,
      json_extract(m.content, '$.text'), CASE WHEN f.id IS NOT NULL THEN json_quote(json_extract(f.content, '$.text')) END, m.deadline_at, m.created_at,
      COALESCE(f.created_at, m.created_at)
    FROM messages m
    JOIN sessions s ON s.id = m.sender_session_id
    JOIN conversation_members t ON t.conversation_id = m.conversation_id AND t.member_kind = 'session' AND t.member != m.sender_session_id
    LEFT JOIN sessions ts ON ts.id = t.member
    LEFT JOIN messages f ON f.n = (SELECT min(n) FROM messages WHERE request_id = m.request_id AND kind = 'final')
    WHERE m.kind = 'request';
    """)
    let requestMessages = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE kind = 'request'")!
    let rows = try Int.fetchOne(db, sql: "SELECT count(*) FROM requests")!
    let unmatched = try String.fetchAll(db, sql: """
    SELECT m.id FROM messages m WHERE m.kind = 'request'
      AND (m.request_id IS NOT m.id OR (SELECT count(*) FROM requests WHERE id = m.request_id) != 1)
    ORDER BY m.n LIMIT 20
    """)
    guard unmatched.isEmpty, rows == requestMessages else {
      throw Unmatched(requestMessages: requestMessages, rows: rows, examples: unmatched)
    }
    let statuses = try Row.fetchAll(db, sql: "SELECT status, count(*) AS n FROM requests GROUP BY status")
    try db.execute(sql: "ALTER TABLE messages DROP COLUMN deadline_at")
    return Backfill(
      requestMessages: requestMessages,
      rows: Dictionary(uniqueKeysWithValues: statuses.map { ($0["status"] as String, $0["n"] as Int) }),
    )
  }
}
