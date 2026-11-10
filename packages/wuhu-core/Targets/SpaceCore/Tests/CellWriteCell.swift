import Wuwei

/// Writes an inbox row the way any cell writes: with its own `db`.
@Cell
struct Scribe {
  mutating func note(_ recipient: String) throws -> Int64 {
    try db.execute(
      "INSERT INTO notifications (recipient, source, kind, payload, created_at, grp) VALUES (?, 's', 'session_settled', '{}', '2026-11-11T00:00:00.000Z', 'shared')",
      .text(recipient),
    )
    return db.one("SELECT COUNT(*) FROM notifications WHERE recipient = ?", .text(recipient))!.integer!
  }

  mutating func twice(_ id: Int64) throws -> Int64 {
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    return id
  }
}
