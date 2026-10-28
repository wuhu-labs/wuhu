import GRDB

enum Migration011 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE INDEX IF NOT EXISTS machine_v2_operations_admission ON machine_v2_operations(machine_id, active, reserved_bytes);
    CREATE INDEX IF NOT EXISTS machine_v2_channels_by_operation ON machine_v2_channels(operation_id);
    """)
  }
}
