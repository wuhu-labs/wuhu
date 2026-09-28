import Foundation
import JSONValue
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct TableTests {
  func makeLogTable(_ space: Space, at rawPath: String = "/data/log.table") async throws -> SpacePath {
    let table = try path(rawPath)
    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    return table
  }

  @Test func createInsertQuery() async throws {
    let space = try makeSpace()
    let table = try await makeLogTable(space)
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("one")]), .insert([.integer(2), .string("two")])], in: .shared, acting: .shared)

    let rows = try await space.query("SELECT n, s FROM \"/data/log.table\" ORDER BY n")
    #expect(rows.columns == ["n", "s"])
    #expect(rows.rows.count == 2)
    #expect(rows.rows[0] == [.integer(1), .text("one")])
    #expect(rows.rows[1] == [.integer(2), .text("two")])
  }

  @Test func updateAndDeleteRows() async throws {
    let space = try makeSpace()
    let table = try await makeLogTable(space)
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    let ids = try await space.query("SELECT \"id\" FROM \"/data/log.table\"")
    guard case let .integer(id) = ids.rows[0][0] else { Issue.record("no id"); return }

    _ = try await space.mutateRows(table, [.update(id: id, [.integer(9), .string("z")])], in: .shared, acting: .shared)
    let updated = try await space.query("SELECT n, s FROM \"/data/log.table\"")
    #expect(updated.rows == [[.integer(9), .text("z")]])

    _ = try await space.mutateRows(table, [.delete(id: id)], in: .shared, acting: .shared)
    let empty = try await space.query("SELECT n, s FROM \"/data/log.table\"")
    #expect(empty.rows.isEmpty)
  }

  @Test func tableMoveRenamesMaterialization() async throws {
    let space = try makeSpace()
    let table = try await makeLogTable(space, at: "/a/log.table")
    _ = try await space.mutateRows(table, [.insert([.integer(5), .string("keep")])], in: .shared, acting: .shared)
    try await space.fs(.shared).move("/a/log.table", to: "/b/log.table")

    let rows = try await space.query("SELECT n, s FROM \"/b/log.table\"")
    #expect(rows.rows == [[.integer(5), .text("keep")]])
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT n FROM \"/a/log.table\"") }
  }
}

@Suite struct AuthorizerTests {
  func seed(_ space: Space) async throws {
    _ = try await space.writeText("/note.md", "---\nkind: note\n---\n[x](/other.md)")
    let table = try path("/data/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(7)])], in: .shared, acting: .shared)
  }

  @Test func inducedTablesAreQueryable() async throws {
    let space = try makeSpace()
    try await seed(space)
    let docs = try await space.query("SELECT path, kind FROM docs")
    #expect(docs.rows == [[.text("/note.md"), .text("note")]])
    let links = try await space.query("SELECT dst FROM links")
    #expect(links.rows == [[.text("/other.md")]])
  }

  @Test func materializedPathTableIsQueryable() async throws {
    let space = try makeSpace()
    try await seed(space)
    let rows = try await space.query("SELECT n FROM \"/data/t.table\"")
    #expect(rows.rows == [[.integer(7)]])
  }

  @Test func jsonTableFunctionsAreQueryable() async throws {
    let space = try makeSpace()
    try await seed(space)
    let rows = try await space.query(
      "SELECT path FROM docs WHERE path IN (SELECT value FROM json_each(?))",
      arguments: [.string(#"["/note.md", "/gone.md"]"#)],
    )
    #expect(rows.rows == [[.text("/note.md")]])
  }

  @Test func sqliteMasterIsDenied() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT name FROM sqlite_master") }
  }

  @Test func pragmaIsDenied() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.self) { _ = try await space.query("PRAGMA table_list") }
  }

  @Test func substrateTableIsDenied() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT rev FROM revisions") }
  }

  @Test func writeThroughQueryIsDenied() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.self) { _ = try await space.query("INSERT INTO docs (path, title) VALUES ('/x', 'x')") }
  }

  @Test func unknownRelationThrows() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT * FROM nope") }
  }

  @Test func deniedQueryNamesTheTable() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.queryForbiddenTable("revisions")) {
      _ = try await space.query("SELECT rev FROM revisions")
    }
  }

  @Test func forbiddenTableOutranksUnknownColumn() async throws {
    let space = try makeSpace()
    try await seed(space)
    await #expect(throws: SpaceError.queryForbiddenTable("revisions")) {
      _ = try await space.query("SELECT rev FROM revisions ORDER BY nope")
    }
  }
}
