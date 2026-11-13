import StructuredQueries
import Wuwei
import WuweiQueries

@Cell
struct Scribe {
  static let schema = ["CREATE TABLE scribe_unowned_probe (n INTEGER NOT NULL)"]

  func unownedProbes() -> Int { db.rows(ScribeUnownedProbe.all).count }
  mutating func insertUnownedProbe() throws { try db.execute(ScribeUnownedProbe.insert { ScribeUnownedProbe(n: 1) }) }
  mutating func deleteUnownedProbes() throws { try db.execute(ScribeUnownedProbe.delete()) }

  func probes() -> Int { db.rows(ScribeSchema.where { $0.kind.eq("scribe-probe") }).count }

  mutating func twice(_ id: Int64) throws -> Int64 {
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    try db.execute("INSERT INTO wuwei_schema (kind, applied) VALUES ('scribe-probe', ?)", .integer(id))
    return id
  }
}

@Table("scribe_unowned_probe")
private struct ScribeUnownedProbe {
  let n: Int
}

@Table("wuwei_schema")
private struct ScribeSchema {
  let kind: String
  let applied: Int
}
