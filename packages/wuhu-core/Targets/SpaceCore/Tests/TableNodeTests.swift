import Foundation
import JSONValue
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct TableNodeTests {
  func makeTable(_ space: Space, at rawPath: String) async throws -> SpacePath {
    let table = try path(rawPath)
    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    return table
  }

  @Test func listAndStatSeeTables() async throws {
    let space = try makeSpace()
    _ = try await makeTable(space, at: "/data/log.table")
    _ = try await space.writeText("/data/a.md", "x")

    let entries = try await space.fs(.shared).list("/data").1
    #expect(entries.map(\.name) == ["a.md", "log.table"])
    #expect(entries.map(\.kind) == [.file, .table])

    let entry = try await space.fs(.shared).stat("/data/log.table")
    #expect(entry.kind == .table)
  }

  @Test func tableIsDeletableThroughFS() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space, at: "/data/log.table")
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)

    try await space.fs(.shared).delete("/data/log.table", ifMatch: nil)

    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).stat("/data/log.table") }
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT n FROM \"/data/log.table\"") }
    let history = try await space.history(table, in: .shared)
    if case .delete = history.last?.2 {} else { Issue.record("last change should be a delete") }

    _ = try await makeTable(space, at: "/data/log.table")
    let rows = try await space.query("SELECT n FROM \"/data/log.table\"")
    #expect(rows.rows.isEmpty)
  }

  @Test func directoryDeleteRemovesContainedTable() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space, at: "/a/log.table")
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    _ = try await space.writeText("/a/x.md", "x")

    try await space.fs(.shared).delete("/a", ifMatch: nil)

    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).stat("/a") }
    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).stat("/a/log.table") }
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT n FROM \"/a/log.table\"") }
    #expect(try await space.fs(.shared).list("/").1.isEmpty)

    _ = try await makeTable(space, at: "/a/log.table")
    #expect(try await space.query("SELECT n FROM \"/a/log.table\"").rows.isEmpty)
  }

  @Test func directoryMoveReparentsContainedTable() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space, at: "/a/log.table")
    _ = try await space.mutateRows(table, [.insert([.integer(5), .string("keep")])], in: .shared, acting: .shared)
    _ = try await space.writeText("/a/x.md", "x")

    try await space.fs(.shared).move("/a", to: "/b")

    let rows = try await space.query("SELECT n, s FROM \"/b/log.table\"")
    #expect(rows.rows == [[.integer(5), .text("keep")]])
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT n FROM \"/a/log.table\"") }
    #expect(try await space.fs(.shared).stat("/b/log.table").kind == .table)
    #expect(try await space.readText("/b/x.md") == "x")
    #expect(!(try await space.history(try path("/b/log.table"), in: .shared).isEmpty))
  }

  @Test func checkoutRestoresAMovedTableAtItsOldPath() async throws {
    let space = try makeSpace()
    let table = try path("/a/log.table")
    let schemaOnly = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    let withRows = try await space.mutateRows(
      table, [.insert([.integer(1), .string("one")]), .insert([.integer(2), .string("two")])], in: .shared, acting: .shared,
    )
    try await space.fs(.shared).move("/a/log.table", to: "/b/log.table")

    _ = try await space.checkout(table, rev: schemaOnly, in: .shared, acting: .shared)
    #expect(try await space.fs(.shared).stat("/a/log.table").kind == .table)
    #expect(try await space.query("SELECT n FROM \"/a/log.table\"").rows.isEmpty)

    _ = try await space.checkout(table, rev: withRows, in: .shared, acting: .shared)
    #expect(try await space.query("SELECT n, s FROM \"/a/log.table\" ORDER BY n").rows == [
      [.integer(1), .text("one")], [.integer(2), .text("two")],
    ])
    #expect(try await space.query("SELECT n FROM \"/b/log.table\" ORDER BY n").rows == [[.integer(1)], [.integer(2)]])

    let moved = try path("/b/log.table")
    _ = try await space.mutateRows(moved, [.insert([.integer(3), .string("three")])], in: .shared, acting: .shared)
    for restored in [table, moved] {
      let sql = "SELECT * FROM \"shared:\(restored.rawValue)\" ORDER BY \"id\""
      let live = try await space.dump(sql)
      try await space.rebuildTable(restored)
      #expect(try await space.dump(sql) == live)
    }
  }

  @Test func checkoutRestoresADeletedTable() async throws {
    let space = try makeSpace()
    let table = try path("/data/log.table")
    let schemaOnly = try await space.createTable(table, header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: .shared, acting: .shared)
    let withRows = try await space.mutateRows(table, [.insert([.integer(7)])], in: .shared, acting: .shared)
    try await space.fs(.shared).delete("/data/log.table", ifMatch: nil)

    _ = try await space.checkout(table, rev: schemaOnly, in: .shared, acting: .shared)
    #expect(try await space.query("SELECT n FROM \"/data/log.table\"").rows.isEmpty)
    try await space.fs(.shared).delete("/data/log.table", ifMatch: nil)
    _ = try await space.checkout(table, rev: withRows, in: .shared, acting: .shared)
    #expect(try await space.query("SELECT n FROM \"/data/log.table\"").rows == [[.integer(7)]])
  }

  @Test func checkoutRestoresATableMovedToAnotherGroup() async throws {
    let space = try makeSpace()
    let team = GroupID(rawValue: "team")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('team', '2026-01-01T00:00:00.000Z')")
    }
    let table = try path("/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: .shared, acting: .shared)
    let withRows = try await space.mutateRows(table, [.insert([.integer(4)])], in: .shared, acting: .shared)
    try await space.move("/t.table", in: .shared, to: "/t.table", in: team, replacing: false, acting: .shared)

    _ = try await space.checkout(table, rev: withRows, in: .shared, acting: .shared)
    #expect(try await space.query("SELECT n FROM \"/t.table\"").rows == [[.integer(4)]])
    #expect(try await space.query("SELECT n FROM \"/t.table\"", as: Principal(actor: .anonymous, group: team)).rows == [[.integer(4)]])
  }

  /// Schema versions outlive a move or a delete, so a path a table left must read as no table: mutate and alter
  /// there are notATable (a 400), never the SQL error of a materialized table that is gone.
  @Test func mutateAndAlterWhereATableWasAreNotATable() async throws {
    let space = try makeSpace()
    let team = GroupID(rawValue: "team")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('team', '2026-01-01T00:00:00.000Z')")
    }
    let header = TableHeader(columns: [TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text)])
    _ = try await makeTable(space, at: "/moved.table")
    try await space.fs(.shared).move("/moved.table", to: "/elsewhere.table")
    _ = try await makeTable(space, at: "/crossed.table")
    try await space.move("/crossed.table", in: .shared, to: "/crossed.table", in: team, replacing: false, acting: .shared)
    _ = try await makeTable(space, at: "/deleted.table")
    try await space.fs(.shared).delete("/deleted.table", ifMatch: nil)

    for gone in ["/moved.table", "/crossed.table", "/deleted.table"] {
      let table = try path(gone)
      await #expect(throws: SpaceError.notATable(gone)) {
        _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
      }
      await #expect(throws: SpaceError.notATable(gone)) {
        _ = try await space.alterTable(table, header: header, in: .shared, acting: .shared)
      }
    }
    _ = try await space.mutateRows(try path("/elsewhere.table"), [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
  }

  @Test func regularWritesAtTablePathsAreRejected() async throws {
    let space = try makeSpace()
    await #expect(throws: SpaceError.reservedTablePath("/x.table")) {
      _ = try await space.writeText("/x.table", "not a table")
    }
    await #expect(throws: SpaceError.reservedTablePath("/dir/y.table")) {
      _ = try await space.writeText("/dir/y.table", "nope")
    }

    _ = try await space.writeText("/plain.md", "x")
    await #expect(throws: SpaceError.reservedTablePath("/z.table")) {
      try await space.fs(.shared).move("/plain.md", to: "/z.table")
    }

    let table = try await makeTable(space, at: "/data/log.table")
    await #expect(throws: SpaceError.reservedTablePath("/data/log.md")) {
      try await space.fs(.shared).move(table.rawValue, to: "/data/log.md")
    }
  }

  @Test func alterRejectsColumnTypeChange() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space, at: "/data/log.table")
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)

    await #expect(throws: SpaceError.self) {
      _ = try await space.alterTable(table, header: TableHeader(columns: [
        TableColumn(name: "n", type: .text), TableColumn(name: "s", type: .text),
      ]), in: .shared, acting: .shared)
    }

    let liveSQL = "SELECT * FROM \"shared:/data/log.table\" ORDER BY \"id\""
    let live = try await space.dump(liveSQL)
    try await space.rebuildTable(table)
    #expect(try await space.dump(liveSQL) == live)
    #expect(!live.isEmpty)
  }

  @Test func droppedThenReAddedColumnComesBackNull() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space, at: "/data/log.table")
    _ = try await space.mutateRows(table, [.insert([.integer(5), .string("keep")])], in: .shared, acting: .shared)

    _ = try await space.alterTable(table, header: TableHeader(columns: [TableColumn(name: "s", type: .text)]), in: .shared, acting: .shared)
    _ = try await space.alterTable(table, header: TableHeader(columns: [
      TableColumn(name: "s", type: .text), TableColumn(name: "n", type: .integer),
    ]), in: .shared, acting: .shared)

    let expectSQL = "SELECT n, s FROM \"/data/log.table\""
    #expect(try await space.query(expectSQL).rows == [[.null, .text("keep")]])

    let liveSQL = "SELECT * FROM \"shared:/data/log.table\" ORDER BY \"id\""
    let live = try await space.dump(liveSQL)
    try await space.rebuildTable(table)
    #expect(try await space.dump(liveSQL) == live)
    #expect(try await space.query(expectSQL).rows == [[.null, .text("keep")]])
  }

  @Test func historyAndCheckoutCoverTables() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/before.md", "x")
    let revBeforeCreate = Rev(try await space.currentRevision())

    let table = try path("/data/log.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: .shared, acting: .shared)
    let revOneRow = try await space.mutateRows(table, [.insert([.integer(1)])], in: .shared, acting: .shared)
    _ = try await space.alterTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(2), .string("two")])], in: .shared, acting: .shared)

    #expect(try await space.history(table, in: .shared).count == 4)

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "/data/**", group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    let revBefore = try await space.currentRevision()
    let (minted, _) = try await space.checkout(table, rev: revOneRow, in: .shared, acting: .shared)
    #expect(minted.value == revBefore + 1)

    #expect(
      try await space.query("SELECT * FROM \"/data/log.table\"") ==
        Rows(columns: ["id", "n"], decltypes: ["INTEGER", "INTEGER"], rows: [[.integer(1), .integer(1)]]),
    )

    let collected = await awaitItems(events, atLeast: 1)
    #expect(collected == [MutationEvent(group: .shared, path: "/data/log.table", rev: minted.value, kind: .write, entry: .table)])
    #expect(try await space.history(table, in: .shared).last?.2 == .checkout(fromRev: revOneRow.value))

    let liveSQL = "SELECT * FROM \"shared:/data/log.table\" ORDER BY \"id\""
    let live = try await space.dump(liveSQL)
    try await space.rebuildTable(table)
    #expect(try await space.dump(liveSQL) == live)

    _ = try await space.checkout(table, rev: revBeforeCreate, in: .shared, acting: .shared)
    await #expect(throws: SpaceError.self) { _ = try await space.fs(.shared).stat("/data/log.table") }
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT n FROM \"/data/log.table\"") }
  }

  @Test func checkoutOfNeverExistingPathIsNotFoundAndMintsNoRevision() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/f.md", "x")
    let before = try await space.currentRevision()

    await #expect(throws: SpaceError.notFound("/never.md")) {
      _ = try await space.checkout(try path("/never.md"), rev: Rev(before), in: .shared, acting: .shared)
    }
    #expect(try await space.currentRevision() == before)
    #expect(try await space.history(try path("/never.md"), in: .shared).isEmpty)
  }
}
