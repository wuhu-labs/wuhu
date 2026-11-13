/// The documents' rows, owned by the cell of the path they describe. `wmd_snapshots`, `wmd_log` and
/// `wmd_checkpoints` stay as the tables a space rolled from the old server keeps; nothing reads them.
enum Migration037 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE TABLE document_state (
      owner TEXT NOT NULL DEFAULT (cell()), file_rev INTEGER, frontier BLOB NOT NULL,
      next_seq INTEGER NOT NULL, dirty_at INTEGER, not_document TEXT, UNIQUE (owner)
    );
    CREATE TABLE document_snapshot (
      owner TEXT NOT NULL DEFAULT (cell()), snapshot BLOB NOT NULL, UNIQUE (owner)
    );
    CREATE TABLE document_log (
      owner TEXT NOT NULL DEFAULT (cell()), seq INTEGER NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY (owner, seq)
    );
    CREATE TABLE document_checkpoint (
      owner TEXT NOT NULL DEFAULT (cell()), rev INTEGER NOT NULL, frontiers BLOB NOT NULL, PRIMARY KEY (owner, rev)
    );
    """)
  }
}
