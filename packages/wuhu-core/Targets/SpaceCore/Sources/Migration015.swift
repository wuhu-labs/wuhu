import GRDB

enum Migration015 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE groups ADD COLUMN name TEXT;
    UPDATE groups SET name = CASE id WHEN 'shared' THEN 'Shared' ELSE COALESCE(alias, id) END
    WHERE personal_account IS NULL;
    """)
  }
}
