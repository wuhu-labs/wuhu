import StructuredQueries
import Wuwei
import WuweiQueries

@Cell
struct Scribe {
  func probes() -> Int { db.rows(ScribeSchema.where { $0.kind.eq("scribe-probe") }).count }

  mutating func twice(_ id: Int64) throws -> Int64 {
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    return id
  }
}

@Table("wuwei_schema")
private struct ScribeSchema {
  let kind: String
  let applied: Int
}
