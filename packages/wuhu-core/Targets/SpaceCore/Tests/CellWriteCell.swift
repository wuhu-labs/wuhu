import Wuwei

@Cell
struct Scribe {
  mutating func twice(_ id: Int64) throws -> Int64 {
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    return id
  }
}
