enum Migration033 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DELETE FROM machine_v2_operations WHERE owner_scope LIKE 'exec/%';
    DELETE FROM machine_v2_retention WHERE id NOT IN (SELECT id FROM machine_v2_operations);
    DROP TABLE script_execs;
    DROP TABLE machine_execs;
    DROP TABLE machine_v2_presence;
    CREATE TABLE machine_presence (owner TEXT NOT NULL DEFAULT (cell()), state TEXT NOT NULL, description TEXT, observed INTEGER NOT NULL, lease INTEGER, describeAt INTEGER, describeDeadline INTEGER, describeRetry INTEGER NOT NULL, UNIQUE(owner));
    CREATE TABLE machine_operations (owner TEXT NOT NULL DEFAULT (cell()), id TEXT PRIMARY KEY, operation TEXT NOT NULL, caller TEXT, toolCall TEXT, script TEXT, stream TEXT, request TEXT NOT NULL, recipient TEXT, state TEXT NOT NULL, opened INTEGER NOT NULL, dispatched INTEGER NOT NULL, background INTEGER NOT NULL, delivered INTEGER NOT NULL, created INTEGER NOT NULL, stdout INTEGER NOT NULL, stderr INTEGER NOT NULL, stdin INTEGER NOT NULL, stdinEnded INTEGER NOT NULL, cursor INTEGER NOT NULL, consumed INTEGER NOT NULL, tail BLOB NOT NULL, cut INTEGER, snapshot TEXT, diagnostic TEXT, stop TEXT, stopSent INTEGER NOT NULL, stopAt INTEGER, answerAt INTEGER, endedChannels TEXT NOT NULL, terminalAcks TEXT NOT NULL, flights TEXT NOT NULL);
    """)
  }
}
