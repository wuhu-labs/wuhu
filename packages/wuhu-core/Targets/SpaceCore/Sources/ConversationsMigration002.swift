enum ConversationsMigration002 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    ALTER TABLE push_relay_grants DROP COLUMN platform;
    ALTER TABLE push_relay_grants DROP COLUMN updated_at;
    ALTER TABLE web_push_subscriptions DROP COLUMN updated_at;
    """)
  }
}
