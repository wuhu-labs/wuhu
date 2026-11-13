import DeterministicDependencies
import Foundation
import JSONValue
@testable import SpaceCore
import SpaceFS
import Testing

@Suite(.deterministicDependencies) struct RebuildEquivalenceTests {
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

    let materializedSQL = "SELECT * FROM \"/data/log.table\" ORDER BY \"id\""
    let before = try await space.dump(materializedSQL)
    try await space.rebuildTable(table)
    let after = try await space.dump(materializedSQL)
    #expect(before == after)
    #expect(!before.isEmpty)
  }

  private func quoted(_ path: SpacePath) -> String {
    "\"" + path.rawValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
