import Clocks
import Foundation
import JSONValue
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct ObserveTests {
  @Test func oneEventPerFilesystemMutation() async throws {
    let space = try makeSpace()
    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    _ = try await space.writeText("/a.md", "one")
    _ = try await space.writeText("/b.md", "two")
    try await space.fs(.shared).delete("/a.md", ifMatch: nil)
    let collected = await awaitItems(events, atLeast: 3)

    #expect(collected.count == 3)
    #expect(collected[0] == MutationEvent(group: .shared, path: "/a.md", rev: 1, kind: .write, entry: .file))
    #expect(collected[1] == MutationEvent(group: .shared, path: "/b.md", rev: 2, kind: .write, entry: .file))
    #expect(collected[2] == MutationEvent(group: .shared, path: "/a.md", rev: 3, kind: .delete, entry: nil))
  }

  @Test func globFiltersFilesystemEvents() async throws {
    let space = try makeSpace()
    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "/notes/**", group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    _ = try await space.writeText("/other.md", "x")
    _ = try await space.writeText("/notes/todo.md", "y")
    let collected = await awaitItems(events, atLeast: 1)

    #expect(collected.count == 1)
    #expect(collected[0].path == "/notes/todo.md")
  }

  @Test func globFiltersTableEvents() async throws {
    let space = try makeSpace()
    let header = TableHeader(columns: [TableColumn(name: "n", type: .integer)])
    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "/data/**", group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    _ = try await space.createTable(try path("/other.table"), header: header, in: .shared, acting: .shared)
    _ = try await space.mutateRows(try path("/other.table"), [.insert([.integer(1)])], in: .shared, acting: .shared)
    _ = try await space.createTable(try path("/data/t.table"), header: header, in: .shared, acting: .shared)
    _ = try await space.mutateRows(try path("/data/t.table"), [.insert([.integer(2)])], in: .shared, acting: .shared)
    let collected = await awaitItems(events, atLeast: 2)
    await settle()

    #expect(collected.map(\.path) == ["/data/t.table", "/data/t.table"])
    #expect(collected.map(\.kind) == [.write, .write])
  }

  @Test func recursiveDeleteEmitsOneEventPerAffectedPath() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/dir/a.md", "a")
    _ = try await space.writeText("/dir/sub/b.md", "b")
    _ = try await space.createTable(try path("/dir/t.table"), header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer),
    ]), in: .shared, acting: .shared)

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "/dir/**", group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    try await space.fs(.shared).delete("/dir", ifMatch: nil)
    let collected = await awaitItems(events, atLeast: 4)

    #expect(collected.count == 4)
    #expect(collected.allSatisfy { $0.kind == .delete })
    #expect(Set(collected.map(\.rev)).count == 1)
    #expect(Set(collected.map(\.path)) == ["/dir/a.md", "/dir/sub/b.md", "/dir/sub", "/dir/t.table"])
  }

  @Test func recursiveMoveEmitsOneEventPerAffectedPath() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/src/a.md", "a")
    _ = try await space.writeText("/src/sub/b.md", "b")
    _ = try await space.createTable(try path("/src/t.table"), header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer),
    ]), in: .shared, acting: .shared)

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "/src/**", group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    try await space.fs(.shared).move("/src", to: "/dst")
    let collected = await awaitItems(events, atLeast: 4)

    #expect(collected.count == 4)
    #expect(collected.allSatisfy { $0.kind == .move })
    let pairs = Set(collected.map { "\($0.from ?? "?") -> \($0.path)" })
    #expect(pairs == [
      "/src/a.md -> /dst/a.md",
      "/src/sub -> /dst/sub",
      "/src/sub/b.md -> /dst/sub/b.md",
      "/src/t.table -> /dst/t.table",
    ])
    let kinds = Dictionary(uniqueKeysWithValues: collected.map { ($0.path, $0.entry!) })
    #expect(kinds == [
      "/dst/a.md": .file,
      "/dst/sub": .directory,
      "/dst/sub/b.md": .file,
      "/dst/t.table": .table,
    ])
  }

  @Test func queryObserveFiresOnlyOnResultDiff() async throws {
    let clock = ImmediateClock()
    let space = try makeSpace(clock: clock)
    let table = try path("/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)

    let results = Collector<Rows>()
    let stream = await space.observeQuery("SELECT n FROM \"/t.table\" ORDER BY n", throttle: .zero)
    let consumer = Task { do { for try await rows in stream { await results.append(rows) } } catch {} }
    defer { consumer.cancel() }

    _ = await awaitItems(results, atLeast: 1)
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    _ = await awaitItems(results, atLeast: 2)
    let ids = try await space.query("SELECT \"id\" FROM \"/t.table\"")
    guard case let .integer(id) = ids.rows[0][0] else { Issue.record("no id"); return }
    _ = try await space.mutateRows(table, [.update(id: id, [.integer(1), .string("changed")])], in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(2), .string("b")])], in: .shared, acting: .shared)
    let collected = await awaitItems(results, atLeast: 3)
    await settle()

    #expect(collected.count == 3)
    #expect(collected[0].rows.isEmpty)
    #expect(collected[1].rows == [[.integer(1)]])
    #expect(collected[2].rows == [[.integer(1)], [.integer(2)]])
  }

  @Test func queryObserveThrottleHeldUntilClockAdvances() async throws {
    let clock = TestClock()
    let space = try makeSpace(clock: clock)
    let table = try path("/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: .shared, acting: .shared)

    let results = Collector<Rows>()
    let stream = await space.observeQuery("SELECT n FROM \"/t.table\"", throttle: .seconds(10))
    let consumer = Task { do { for try await rows in stream { await results.append(rows) } } catch {} }
    defer { consumer.cancel() }

    _ = await awaitItems(results, atLeast: 1)
    _ = try await space.mutateRows(table, [.insert([.integer(1)])], in: .shared, acting: .shared)
    await settle()
    #expect(await results.items.count == 1)

    for _ in 0 ..< 300 where await results.items.count < 2 {
      await clock.advance(by: .seconds(10))
      await settle(.milliseconds(5))
    }
    let collected = await results.items
    #expect(collected.count == 2)
    #expect(collected[1].rows == [[.integer(1)]])
  }

  @Test func queryObserveTracksInducedTables() async throws {
    let clock = ImmediateClock()
    let space = try makeSpace(clock: clock)

    let results = Collector<Rows>()
    let stream = await space.observeQuery("SELECT path FROM docs ORDER BY path", throttle: .zero)
    let consumer = Task { do { for try await rows in stream { await results.append(rows) } } catch {} }
    defer { consumer.cancel() }

    _ = await awaitItems(results, atLeast: 1)
    _ = try await space.writeText("/note.md", "---\nkind: note\n---\nhi")
    let collected = await awaitItems(results, atLeast: 2)

    #expect(collected.count == 2)
    #expect(collected[0].rows.isEmpty)
    #expect(collected[1].rows == [[.text("/note.md")]])
  }

  @Test func queryObserveSetupErrorTerminatesWithError() async throws {
    let space = try makeSpace()
    let stream = await space.observeQuery("SELECT rev FROM revisions", throttle: .zero)
    await #expect(throws: SpaceError.self) {
      for try await _ in stream { Issue.record("forbidden query must not yield") }
    }
  }

  @Test func queryObserveTerminatesWithErrorWhenTableDisappears() async throws {
    let clock = ImmediateClock()
    let space = try makeSpace(clock: clock)
    let table = try path("/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [TableColumn(name: "n", type: .integer)]), in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(1)])], in: .shared, acting: .shared)

    let results = Collector<Rows>()
    let stream = await space.observeQuery("SELECT n FROM \"/t.table\" UNION ALL SELECT 0 FROM docs", throttle: .zero)
    let outcome = Task { for try await rows in stream { await results.append(rows) } }

    _ = await awaitItems(results, atLeast: 1)
    try await space.fs(.shared).delete("/t.table", ifMatch: nil)
    _ = try await space.writeText("/note.md", "---\nkind: note\n---\nhi")

    await #expect(throws: SpaceError.unknownRelation("/t.table")) { try await outcome.value }
  }
}
