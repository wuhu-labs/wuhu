enum Migration038 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    DROP TABLE machine_v2_output;
    DROP TABLE machine_v2_channels;
    DROP TABLE machine_v2_operations;
    DROP TABLE machine_v2_retention;
    DROP TABLE machine_v2_maintenance;
    DROP TABLE machine_v2_key_check;
    ALTER TABLE machine_file_operations ADD COLUMN inputOffsets TEXT NOT NULL DEFAULT '{}';
    ALTER TABLE machine_file_operations ADD COLUMN inputEnded TEXT NOT NULL DEFAULT '[]';
    ALTER TABLE machine_file_operations ADD COLUMN inputReady INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE machine_file_operations ADD COLUMN inputChannels TEXT NOT NULL DEFAULT '[]';
    """)
  }
}
