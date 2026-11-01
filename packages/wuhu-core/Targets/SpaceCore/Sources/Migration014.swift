import GRDB

enum Migration014 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE wmd_snapshots (
      grp TEXT NOT NULL,
      path TEXT NOT NULL,
      snapshot BLOB NOT NULL,
      PRIMARY KEY (grp, path)
    );
    CREATE TABLE wmd_log (
      grp TEXT NOT NULL,
      path TEXT NOT NULL,
      seq INTEGER NOT NULL,
      bytes BLOB NOT NULL,
      PRIMARY KEY (grp, path, seq)
    );
    CREATE TABLE wmd_checkpoints (
      grp TEXT NOT NULL,
      path TEXT NOT NULL,
      rev INTEGER NOT NULL,
      frontiers BLOB NOT NULL,
      PRIMARY KEY (grp, path, rev)
    );
    """)
  }
}
