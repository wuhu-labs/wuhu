#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Wuwei

extension Space {
  func dump(_ sql: String) async throws -> [String] {
    let rows = try await query(sql)
    return rows.rows.map { row in row.map { cell in
      switch cell {
      case .null: ""
      case let .integer(value): String(value)
      case let .real(value): String(value)
      case let .text(value): value
      case let .blob(value): Data(value).base64EncodedString()
      }
    }.joined(separator: "|") }
  }

  func rebuildTable(_ path: SpacePath, in group: GroupID = .shared) async throws {
    try await worker.call(FilesCell.ID(group.rawValue)) { cell in
      guard cell.tableExists(path) else { throw SpaceError.notATable(path.rawValue) }
      let (header, rows) = try cell.tableState(path, ceiling: cell.currentRevision())
      try cell.db.execute("DROP TABLE \(Tables.quoted(group, path))")
      try cell.db.execute(Tables.createMaterializedSQL(path, group: group, header: header))
      for row in rows { try cell.insertMaterializedRow(path, header: header, rowID: row.id, cells: header.columns.map { row.cells[$0.name] ?? .null }) }
      try cell.syncSequence(path)
    }
  }
}
