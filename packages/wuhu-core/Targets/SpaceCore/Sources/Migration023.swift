enum Migration023 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DELETE FROM subscription_slots WHERE owner_kind = 'session' AND json_type(payload, '$.kind.stream') IS NOT NULL
      AND json_extract(payload, '$.handler') IS NULL;
    """)
  }
}
