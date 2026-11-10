import GRDB

// An attachment is a row of its conversation, not a file of the group's journal. The journal's rows stay where they are; nothing reads them.
enum Migration029 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE attachments (
      conversation_id TEXT NOT NULL,
      path TEXT NOT NULL,
      blob TEXT NOT NULL,
      size INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (conversation_id, path)
    ) WITHOUT ROWID;
    INSERT INTO attachments (conversation_id, path, blob, size, created_at)
    SELECT c.id, h.path, h.blob_hash, h.size, h.mtime
    FROM fs_heads AS h JOIN conversations AS c
      ON c.grp = h.grp AND c.id = substr(h.path, 18, instr(substr(h.path, 18), '/') - 1)
    WHERE h.kind = 'file' AND h.blob_hash IS NOT NULL AND h.path GLOB '/_/conversations/*/attachments/*';
    """)
  }
}
