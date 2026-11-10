import StructuredQueries
import Testing
import WuweiNeo
import WuweiNeoQueries

@Table("shelf_book")
struct Book: Owned, Equatable {
  let id: String
  var title: String
}

/// Keeps its books through StructuredQueries, in a table every shelf shares on the shared backend.
@Cell
struct Shelf {
  static let schema = ["CREATE TABLE shelf_book (id TEXT PRIMARY KEY, \(ownerColumn), title TEXT NOT NULL)"]

  func books() -> [Book] {
    db.rows(Book.order(by: \.id))
  }

  func allTitles() -> [String] {
    db.rows(Book.unscoped.order(by: \.title).select(\.title))
  }

  mutating func add(_ id: String, _ title: String) throws {
    try db.execute(Book.insert { Book(id: id, title: title) })
  }

  mutating func retitleAll(_ title: String) throws {
    try db.execute(Book.update { $0.title = title })
  }

  mutating func clear() throws {
    try db.execute(Book.delete())
  }

  mutating func put(_ id: String, _ title: String) throws {
    try db.execute(Book.upsert { Book(id: id, title: title) })
  }
}

@Suite struct QueriesTests {
  let left = Shelf.ID("left")
  let right = Shelf.ID("right")

  @Test(arguments: [false, true])
  func aStatementKeepsToTheCellsOwnRows(shared: Bool) throws {
    let world = World(shared: shared)
    _ = try world.node("a", [.cell(Shelf.self)])
    let client = try world.client()
    client.send(left).add("l1", "Dune")
    client.send(left).add("l2", "Emma")
    client.send(right).add("r1", "Ulysses")
    world.run(for: .seconds(2))
    client.send(right).retitleAll("Odyssey")
    client.send(left).clear()
    client.send(left).add("l3", "Beloved")
    world.run(for: .seconds(2))
    #expect(client.cell(left).books() == [Book(id: "l3", title: "Beloved")])
    #expect(client.cell(right).books() == [Book(id: "r1", title: "Odyssey")])
    #expect(client.cell(right).allTitles() == (shared ? ["Beloved", "Odyssey"] : ["Odyssey"]))
  }

  @Test func anUpsertOntoAnotherCellsRowIsRefusedOnTheSharedBackend() throws {
    let world = World(shared: true)
    _ = try world.node("a", [.cell(Shelf.self)])
    let client = try world.client()
    client.send(left).put("b", "Dune")
    world.run(for: .seconds(2))
    client.send(right).put("b", "Emma")
    client.send(left).put("b", "Middlemarch")
    world.run(for: .seconds(2))
    #expect(client.cell(left).books() == [Book(id: "b", title: "Middlemarch")])
    #expect(client.cell(right).books() == [])
  }
}
