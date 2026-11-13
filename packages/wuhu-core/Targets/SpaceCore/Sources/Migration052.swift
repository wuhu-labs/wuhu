enum Migration052 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE TABLE document_lineage (
      owner TEXT NOT NULL DEFAULT (cell()), lineage INTEGER NOT NULL, seq INTEGER NOT NULL,
      seed_rev INTEGER, PRIMARY KEY (owner)
    );
    CREATE TABLE document_pending_checkpoint (
      owner TEXT NOT NULL DEFAULT (cell()), seq INTEGER NOT NULL, frontiers BLOB NOT NULL,
      PRIMARY KEY (owner, seq)
    );
    INSERT INTO document_lineage (owner, lineage, seq, seed_rev)
      SELECT owner, 1, 0, file_rev FROM document_state;
    """)
  }
}
