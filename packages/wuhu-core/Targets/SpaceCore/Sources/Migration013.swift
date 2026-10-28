import GRDB

enum Migration013 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    DROP TABLE IF EXISTS machine_v2_trace;
    DROP TABLE IF EXISTS machine_v2_incidents;
    DROP TABLE IF EXISTS machine_v2_problem_index;
    DELETE FROM machine_v2_retention WHERE kind = 'incident';
    DELETE FROM machine_v2_maintenance WHERE id LIKE 'problems/%';
    """)
  }
}
