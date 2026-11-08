import GRDB

enum Migration016 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE usage_window_resets (
      provider TEXT NOT NULL,
      window_name TEXT NOT NULL,
      resets_at REAL NOT NULL,
      PRIMARY KEY (provider, window_name)
    );
    """)
  }
}
