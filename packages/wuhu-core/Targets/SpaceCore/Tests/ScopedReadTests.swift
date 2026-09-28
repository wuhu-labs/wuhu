import Clocks
import Dependencies
import Foundation
@testable import SpaceCore
import SpaceFS
@testable import SpaceSQL
import Synchronization
import Testing

// A catalog that hides rows reaches every read entry point: a query and an
// observation see only what the views admit, and a write to a hidden row
// wakes an observation without telling it anything.
@Suite struct ScopedReadTests {
  static let hiding = ViewCatalog(views: { tables, scope in
    ViewCatalog.groupViews(tables, scope).map { view in
      var view = view
      if view.name == "/t.table" { view.filter = "n <> 99" }
      return view
    }
  })
  static let count = "SELECT count(*) FROM \"/t.table\""

  @Test func aHiddenRowReachesNoQuery() async throws {
    let space = try hidingSpace()
    let table = try await seeded(space)

    #expect(try await space.query(Self.count).rows == [[.integer(1)]])
    #expect(try await space.query("SELECT n FROM \"/t.table\"").rows == [[.integer(1)]])
    #expect(try await space.validateQuery(Self.count, as: .shared(.anonymous)).names == ["shared:" + table.rawValue])
    await #expect(throws: SpaceError.unknownRelation("main./t.table")) {
      try await space.query("SELECT count(*) FROM main.\"/t.table\"")
    }
  }

  @Test func aWriteToAHiddenRowWakesTheObservationButYieldsNothing() async throws {
    let runs = Mutex(0)
    let space = try hidingSpace { sql in if sql == Self.count { runs.withLock { $0 += 1 } } }
    let table = try await seeded(space)
    let hidden = try await space.writer.read { db in
      try Int64.fetchOne(db, sql: "SELECT id FROM \"shared:/t.table\" WHERE n = 99")!
    }

    let results = Collector<Rows>()
    let stream = await space.observeQuery(Self.count, throttle: .zero)
    let consumer = Task { do { for try await rows in stream { await results.append(rows) } } catch {} }
    defer { consumer.cancel() }
    #expect(await awaitItems(results, atLeast: 1).map(\.rows) == [[[.integer(1)]]])

    let before = runs.withLock { $0 }
    _ = try await space.mutateRows(table, [.update(id: hidden, [.integer(99), .string("moved")])], in: .shared, acting: .shared)
    for _ in 0 ..< 500 where runs.withLock({ $0 }) == before {
      await settle(.milliseconds(5))
    }
    #expect(runs.withLock { $0 } > before)
    await settle()
    #expect(await results.items.count == 1)

    _ = try await space.mutateRows(table, [.insert([.integer(2), .string("b")])], in: .shared, acting: .shared)
    #expect(await awaitItems(results, atLeast: 2).map(\.rows) == [[[.integer(1)]], [[.integer(2)]]])
  }

  // The pool draws its secrets at random; whatever they are, no refusal, row
  // or observation frame carries a name shaped like one.
  @Test func nothingReturnedNamesASecret() async throws {
    let space = try hidingSpace()
    _ = try await seeded(space)
    let secret = /(s|__v)[0-9a-f]{32}/

    for sql in [
      "SELECT nope FROM \"/t.table\"",
      "SELECT * FROM \"/t.table\" WHERE",
      "SELECT * FROM temp.sqlite_master",
      "SELECT * FROM pragma_database_list",
      "EXPLAIN SELECT * FROM \"/t.table\"",
      "SELECT json('{' || s) FROM \"/t.table\"",
    ] {
      do {
        _ = try await space.query(sql)
        Issue.record("\(sql) ran")
      } catch {
        #expect(!"\(error) \(String(reflecting: error))".contains(secret), "\(sql): \(error)")
      }
    }
    let rows = try await space.query("SELECT * FROM \"/t.table\"")
    #expect(!"\(rows)".contains(secret))
    for try await frame in await space.observeQuery("SELECT * FROM \"/t.table\"", throttle: .zero) {
      #expect(!"\(frame)".contains(secret))
      break
    }
  }

  private func hidingSpace(trace: (@Sendable (String) -> Void)? = nil) throws -> Space {
    try withDependencies {
      $0.date = .constant(fixedDate)
      $0.continuousClock = ImmediateClock()
    } operation: {
      try Space.temporary(catalog: Self.hiding, trace: trace)
    }
  }

  private func seeded(_ space: Space) async throws -> SpacePath {
    let table = try path("/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")]), .insert([.integer(99), .string("x")])], in: .shared, acting: .shared)
    return table
  }
}
