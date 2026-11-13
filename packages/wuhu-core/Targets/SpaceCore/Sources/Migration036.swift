enum Migration036 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DELETE FROM machine_v2_operations;
    DELETE FROM machine_v2_retention;
    DELETE FROM machine_operations;
    DROP TABLE machine_presence;
    CREATE TABLE machine_presence (owner TEXT NOT NULL DEFAULT (cell()), state TEXT NOT NULL, observed INTEGER NOT NULL, lease INTEGER, describeAt INTEGER, describeDeadline INTEGER, describeRetry INTEGER NOT NULL, leaseMs INTEGER NOT NULL DEFAULT 60000, pollHoldMs INTEGER, pollBytes INTEGER, resultBytes INTEGER, execStdoutWindow INTEGER, execStderrWindow INTEGER, UNIQUE(owner));
    CREATE TABLE machine_descriptions (owner TEXT NOT NULL DEFAULT (cell()), description TEXT NOT NULL, UNIQUE(owner));
    CREATE TABLE machine_file_operations (owner TEXT NOT NULL DEFAULT (cell()), id TEXT PRIMARY KEY, request TEXT NOT NULL, state TEXT NOT NULL, worker TEXT, stream INTEGER, created INTEGER NOT NULL, dispatched INTEGER NOT NULL, delivered INTEGER NOT NULL, stop TEXT, offsets TEXT NOT NULL, offered TEXT NOT NULL, received TEXT NOT NULL, snapshot TEXT, failure TEXT, endedChannels TEXT NOT NULL, terminalAcks TEXT NOT NULL, flights TEXT NOT NULL);
    """)
  }
}
