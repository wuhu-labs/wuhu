enum ConversationsMigration001 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "DROP TABLE message_groups")
  }
}
