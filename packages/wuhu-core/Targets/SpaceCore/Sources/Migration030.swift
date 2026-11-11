import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB

// A generation's system text and tool list are one content-addressed blob, named by hash from its line 0 and from the session's prompt row. Every stored line 0 moves into `blobs`; a prompt stored for a generation without a line 0 never recorded its tools, so its next inference renders it again.
enum Migration030 {
  static func apply(_ db: Database) throws {
    for row in try Row.fetchAll(db, sql: "SELECT session_id, generation, message FROM session_lines WHERE position = 0") {
      let session: String = row["session_id"], generation: Int64 = row["generation"], message: String = row["message"]
      let hash = SHA256.hash(data: Data(message.utf8)).map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
      }.joined()
      try db.execute(sql: "INSERT OR IGNORE INTO blobs (hash, content) VALUES (?, ?)", arguments: [hash, Data(message.utf8)])
      try db.execute(
        sql: "UPDATE session_lines SET message = json_object('rendered', ?) WHERE session_id = ? AND generation = ? AND position = 0",
        arguments: [hash, session, generation],
      )
    }
    try db.execute(sql: """
    CREATE TABLE session_prompts_rendered (
      session_id TEXT NOT NULL PRIMARY KEY,
      generation INTEGER NOT NULL,
      rev INTEGER NOT NULL,
      rendered TEXT,
      session TEXT,
      CHECK ((rendered IS NULL) = (session IS NULL))
    );
    INSERT INTO session_prompts_rendered (session_id, generation, rev, rendered, session)
    SELECT p.session_id, p.generation, p.rev, json_extract(l.message, '$.rendered'), CASE WHEN l.message IS NULL THEN NULL ELSE p.session END
    FROM session_prompts AS p LEFT JOIN session_lines AS l
      ON p.prompt IS NOT NULL AND l.session_id = p.session_id AND l.generation = p.generation AND l.position = 0;
    DROP TABLE session_prompts;
    ALTER TABLE session_prompts_rendered RENAME TO session_prompts;
    """)
  }
}
