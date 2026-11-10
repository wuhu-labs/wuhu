import GRDB

// A request is a row of the conversation its message was posted in. A row with no message was written at its session's creation for a request that never posted: nothing ever heard of it.
enum Migration028 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE requests ADD COLUMN conversation_id TEXT;
    UPDATE requests SET conversation_id = (SELECT conversation_id FROM messages WHERE messages.id = requests.id);
    DELETE FROM requests WHERE conversation_id IS NULL;
    """)
  }
}
