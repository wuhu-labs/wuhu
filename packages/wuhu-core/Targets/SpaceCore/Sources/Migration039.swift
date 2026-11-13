enum Migration039 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    ALTER TABLE document_state ADD COLUMN history TEXT NOT NULL DEFAULT '';
    UPDATE document_state SET history = lower(hex(randomblob(16)));
    """)
  }
}
