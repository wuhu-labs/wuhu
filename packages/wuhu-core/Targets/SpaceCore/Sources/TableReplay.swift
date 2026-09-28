import Foundation
import GRDB
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS

// Replays the schema journal and the row journal interleaved by revision, so a
// column dropped and later re-added comes back NULL for rows written before the
// drop — exactly what the live ALTER TABLE sequence produced.
enum TableReplay {
  struct ReplayedRow {
    let id: Int64
    let cells: [String: JSONValue]
  }

  private enum Event {
    case schema(TableHeader)
    case close(Int64)
    case insert(Int64, String)

    var order: Int {
      switch self {
      case .schema: 0
      case .close: 1
      case .insert: 2
      }
    }
  }

  static func state(_ path: SpacePath, group: GroupID, ceiling: Int64, in db: Database) throws -> (TableHeader, [ReplayedRow]) {
    var events: [(rev: Int64, event: Event)] = []
    let schemas = try Row.fetchAll(
      db,
      sql: "SELECT rev, header_json FROM table_schema_versions WHERE grp = ? AND path = ? AND rev <= ? ORDER BY rev",
      arguments: [group.rawValue, path.rawValue, ceiling],
    )
    for row in schemas {
      events.append((row["rev"], .schema(try Tables.decodeHeader(row["header_json"]))))
    }
    let journal = try Row.fetchAll(
      db,
      sql: "SELECT row_id, created_rev, deleted_rev, payload FROM table_rows WHERE grp = ? AND path = ? AND created_rev <= ?",
      arguments: [group.rawValue, path.rawValue, ceiling],
    )
    for row in journal {
      let id: Int64 = row["row_id"]
      events.append((row["created_rev"], .insert(id, row["payload"])))
      if let deleted: Int64 = row["deleted_rev"], deleted <= ceiling {
        events.append((deleted, .close(id)))
      }
    }
    guard !schemas.isEmpty else { throw SpaceError.notATable(path.rawValue) }
    events.sort { ($0.rev, $0.event.order) < ($1.rev, $1.event.order) }

    var header = TableHeader(columns: [])
    var live: [Int64: [String: JSONValue]] = [:]
    for (_, event) in events {
      switch event {
      case let .schema(next):
        let kept = Set(next.columns.map(\.name))
        for name in Set(header.columns.map(\.name)).subtracting(kept) {
          for id in live.keys { live[id]?.removeValue(forKey: name) }
        }
        header = next
      case let .close(id):
        live[id] = nil
      case let .insert(id, payload):
        let columns = Set(header.columns.map(\.name))
        var cells: [String: JSONValue] = [:]
        for (key, value) in JSONValue.parse(payload)?.object ?? [:] where columns.contains(key) {
          cells[key] = value
        }
        live[id] = cells
      }
    }
    let rows = live.keys.sorted().map { ReplayedRow(id: $0, cells: live[$0]!) }
    return (header, rows)
  }
}
