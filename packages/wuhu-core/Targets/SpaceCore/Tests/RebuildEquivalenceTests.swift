import Foundation
import JSONValue
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct RebuildEquivalenceTests {
  static let markdownBodies = [
    "---\nkind: note\nstatus: open\ntags:\n  - a\n  - b\n---\n# Title\n[link](/other.md)",
    "---\nkind: task\npriority: 3\n---\nbody with [ref](/a.md) and ![img](/img.png)",
    "plain text, no frontmatter, [x](/c/d.md)",
    "# Heading only",
  ]
  static let candidatePaths = ["/a.md", "/b.md", "/c/d.md", "/c/e.md", "/notes/todo.md", "/data/plain.txt", "/other.md"]
  static let candidateDirs = ["/c", "/notes", "/data", "/moved"]
  static let candidateTables = ["/c/t1.table", "/data/t2.table", "/t3.table"]

  @Test func rebuiltHeadsMatchMaintainedHeads() async throws {
    let space = try makeSpace()
    try await applyRandomSpaceMutations(space, count: 300, seed: 0xF00D)
    let headsSQL = "SELECT path, parent_path, kind, blob_hash, size, line_count, etag, rev FROM fs_heads ORDER BY path"
    let before = try await space.dump(headsSQL)
    try await space.rebuildHeads()
    let after = try await space.dump(headsSQL)
    #expect(before == after)
    #expect(!before.isEmpty)
  }

  @Test func rebuiltInducedTablesMatchMaintained() async throws {
    let space = try makeSpace()
    try await applyRandomSpaceMutations(space, count: 300, seed: 0xBEEF)
    let docsSQL = "SELECT path, title, kind, status FROM docs ORDER BY path"
    let linksSQL = "SELECT src, dst FROM links ORDER BY src, dst"
    let attrsSQL = "SELECT path, name, ord, value FROM doc_custom_attrs ORDER BY path, name, ord"
    let docsBefore = try await space.dump(docsSQL)
    let linksBefore = try await space.dump(linksSQL)
    let attrsBefore = try await space.dump(attrsSQL)
    try await space.rebuildInducedTables()
    #expect(try await space.dump(docsSQL) == docsBefore)
    #expect(try await space.dump(linksSQL) == linksBefore)
    #expect(try await space.dump(attrsSQL) == attrsBefore)
    #expect(!docsBefore.isEmpty)
  }

  @Test func rebuiltTableMaterializationMatchesMaintained() async throws {
    let space = try makeSpace()
    let table = try path("/data/log.table")
    let n = TableColumn(name: "n", type: .integer)
    let r = TableColumn(name: "r", type: .real)
    let s = TableColumn(name: "s", type: .text)
    let b = TableColumn(name: "b", type: .blob)
    _ = try await space.createTable(table, header: TableHeader(columns: [n]), in: .shared, acting: .shared)
    try await applyRandomRowMutations(space, table: table, columns: [n], count: 60, seed: 1)
    _ = try await space.alterTable(table, header: TableHeader(columns: [n, r, s, b]), in: .shared, acting: .shared)
    try await applyRandomRowMutations(space, table: table, columns: [n, r, s, b], count: 60, seed: 2)
    _ = try await space.alterTable(table, header: TableHeader(columns: [s, b]), in: .shared, acting: .shared)
    try await applyRandomRowMutations(space, table: table, columns: [s, b], count: 60, seed: 3)
    _ = try await space.alterTable(table, header: TableHeader(columns: [s, b, n]), in: .shared, acting: .shared)
    try await applyRandomRowMutations(space, table: table, columns: [s, b, n], count: 60, seed: 4)

    let materializedSQL = "SELECT * FROM \(Tables.quoted(.shared, table)) ORDER BY \"id\""
    let before = try await space.dump(materializedSQL)
    try await space.rebuildTable(table)
    let after = try await space.dump(materializedSQL)
    #expect(before == after)
    #expect(!before.isEmpty)
  }

  private func quoted(_ path: SpacePath) -> String {
    "\"" + path.rawValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private func applyRandomSpaceMutations(_ space: Space, count: Int, seed: UInt64) async throws {
    var rng = SeededRNG(seed: seed)
    func pick(_ candidates: [String]) -> String {
      candidates[Int(rng.next() % UInt64(candidates.count))]
    }
    for _ in 0 ..< count {
      switch rng.next() % 10 {
      case 0, 1, 2:
        let body = Self.markdownBodies[Int(rng.next() % UInt64(Self.markdownBodies.count))]
        _ = try? await space.writeText(pick(Self.candidatePaths), body + "\n<!-- \(rng.next()) -->")
      case 3:
        try? await space.fs(.shared).delete(pick(Self.candidatePaths), ifMatch: nil)
      case 4:
        try? await space.fs(.shared).move(pick(Self.candidatePaths), to: pick(Self.candidatePaths))
      case 5:
        try? await space.fs(.shared).delete(pick(Self.candidateDirs), ifMatch: nil)
      case 6:
        try? await space.fs(.shared).move(pick(Self.candidateDirs), to: pick(Self.candidateDirs))
      case 7:
        _ = try? await space.createTable(
          try path(pick(Self.candidateTables)),
          header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]),
          in: .shared, acting: .shared,
        )
      case 8:
        _ = try? await space.mutateRows(try path(pick(Self.candidateTables)), [.insert([.integer(Int(rng.next() % 1000))])], in: .shared, acting: .shared)
      default:
        try? await space.fs(.shared).move(pick(Self.candidateTables), to: pick(Self.candidateTables))
      }
    }
  }

  private func applyRandomRowMutations(_ space: Space, table: SpacePath, columns: [TableColumn], count: Int, seed: UInt64) async throws {
    var rng = SeededRNG(seed: seed)
    func cell(for column: TableColumn) -> JSONValue {
      if rng.next() % 6 == 0 { return .null }
      switch column.type {
      case .integer:
        return rng.next() % 2 == 0 ? .integer(Int(rng.next() % 1000)) : .bool(rng.next() % 2 == 0)
      case .real:
        return .number(Double(rng.next() % 10000) / 8)
      case .text:
        switch rng.next() % 4 {
        case 0: return .array([.integer(Int(rng.next() % 10)), .string("x")])
        case 1: return .object(["k": .integer(Int(rng.next() % 10)), "s": .string("v")])
        default: return .string("v\(rng.next() % 1000)")
        }
      case .blob:
        return .string(Data((0 ..< 4).map { _ in UInt8(truncatingIfNeeded: rng.next()) }).base64EncodedString())
      case .boolean:
        return .bool(rng.next() % 2 == 0)
      case .json:
        switch rng.next() % 4 {
        case 0: return .array([.integer(Int(rng.next() % 10)), .string("x")])
        case 1: return .object(["k": .integer(Int(rng.next() % 10))])
        case 2: return .integer(Int(rng.next() % 1000))
        default: return .string("v\(rng.next() % 1000)")
        }
      }
    }
    func cells() -> [JSONValue] {
      columns.map(cell(for:))
    }
    for _ in 0 ..< count {
      let ids = try await liveIDs(space, table: table)
      switch rng.next() % 4 {
      case 0, 1:
        _ = try await space.mutateRows(table, [.insert(cells())], in: .shared, acting: .shared)
      case 2 where !ids.isEmpty:
        _ = try await space.mutateRows(table, [.update(id: ids[Int(rng.next() % UInt64(ids.count))], cells())], in: .shared, acting: .shared)
      case 3 where !ids.isEmpty:
        _ = try await space.mutateRows(table, [.delete(id: ids[Int(rng.next() % UInt64(ids.count))])], in: .shared, acting: .shared)
      default:
        _ = try await space.mutateRows(table, [.insert(cells())], in: .shared, acting: .shared)
      }
    }
  }

  private func liveIDs(_ space: Space, table: SpacePath) async throws -> [Int64] {
    let rows = try await space.query("SELECT \"id\" FROM \(quoted(table)) ORDER BY \"id\"")
    return rows.rows.compactMap { if case let .integer(value) = $0[0] { value } else { nil } }
  }
}
