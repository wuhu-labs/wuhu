enum Migration055 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DROP TABLE IF EXISTS execution_worker_owners;
    DROP TABLE IF EXISTS fs_heads_by_parent;
    DROP TABLE IF EXISTS notifications_retired;
    DROP TABLE IF EXISTS schema_compactions;
    DROP TABLE IF EXISTS session_command_tokens;
    DROP TABLE IF EXISTS session_context;
    DROP TABLE IF EXISTS session_generations;
    DROP TABLE IF EXISTS session_worker_assignments;
    DROP TABLE IF EXISTS session_worker_incarnations;
    DROP TABLE IF EXISTS worker_script_owners;
    DROP TABLE IF EXISTS wmd_checkpoints;
    DROP TABLE IF EXISTS wmd_log;
    DROP TABLE IF EXISTS wmd_snapshots;
    """)
  }
}
