import Foundation
import Scratch
import SpaceCore
import SpaceFS
import Testing

@Suite struct SpaceMemoryTests {
  @Test func constructionAndQueriesCreateNoScratchDatabase() async throws {
    let folder = try ScratchFolder("memory-contract")
    let root = folder.url.deletingLastPathComponent()
    func databases() throws -> Set<String> {
      Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
        $0.wholeMatch(of: /space-[0-9A-Fa-f-]{36}/) != nil
          && FileManager.default.fileExists(atPath: root.appending(path: $0).appending(path: "space.sqlite").path)
      })
    }
    let before = try databases()
    let space = try Space.inMemory()
    _ = try await space.fs(.shared).write("/memory.md", Data("memory".utf8), ifMatch: nil)
    let rows = try await space.query("SELECT path FROM docs", as: .shared(.anonymous))
    #expect(rows.rows == [[.text("/memory.md")]])
    #expect(try databases() == before)
    try await space.close()
  }

  @Test func independentDatabasesShareNeitherIdentityNorSchemaNorRows() async throws {
    let first = try Space.inMemory(), second = try Space.inMemory()
    #expect(try await first.identity() != (try await second.identity()))
    let table = try SpacePath(validating: "/values.table")
    let header = TableHeader(columns: [.init(name: "value", type: .text)])
    _ = try await first.createTable(table, header: header, in: .shared, acting: .shared)
    _ = try await first.mutateRows(table, [.insert([.string("first")])], in: .shared, acting: .shared)
    #expect(try await first.query("SELECT value FROM \"/values.table\"", as: .shared(.anonymous)).rows == [[.text("first")]])
    await #expect(throws: SpaceError.unknownRelation("/values.table")) {
      _ = try await second.query("SELECT value FROM \"/values.table\"", as: .shared(.anonymous))
    }
    _ = try await second.createTable(table, header: header, in: .shared, acting: .shared)
    #expect(try await second.query("SELECT value FROM \"/values.table\"", as: .shared(.anonymous)).rows.isEmpty)
    _ = try await first.mutateRows(table, [.insert([.string("later")])], in: .shared, acting: .shared)
    #expect(try await first.query("SELECT value FROM \"/values.table\" ORDER BY id", as: .shared(.anonymous)).rows == [[.text("first")], [.text("later")]])
    try await first.close()
    try await second.close()
  }
}
