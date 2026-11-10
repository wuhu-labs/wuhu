import GRDB

enum Migration022 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    DELETE FROM subscription_slots WHERE owner_kind = 'session' AND json_type(payload, '$.kind.timer') IS NOT NULL
      AND json_extract(payload, '$.handler') IS NULL;
    """)
  }
}
