enum Migration054 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE INDEX session_queue_topic ON session_queue (session_id, topic, id) WHERE topic IS NOT NULL;
    CREATE INDEX wuwei_addressable_holder ON wuwei_addressable (holder, expires_at);
    """)
  }
}
