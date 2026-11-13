// A request has no kind and no key: what a session is for is its tags.
enum Migration027 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DROP INDEX requests_by_key;
    DROP INDEX requests_by_kind_status;
    ALTER TABLE requests DROP COLUMN key;
    ALTER TABLE requests DROP COLUMN kind;
    """)
  }
}
