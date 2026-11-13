// A generation's line 0 is the key its rendered prompt is found by; without this index the lookup walks
// every line of every session of the group.
enum Migration049 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: "CREATE INDEX session_lines_preamble ON session_lines (message) WHERE position = 0")
  }
}
