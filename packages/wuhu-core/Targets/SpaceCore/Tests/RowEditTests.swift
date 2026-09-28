import Clocks
import Foundation
import JSONValue
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct RowEditTests {
  func makeTable(_ space: Space) async throws -> SpacePath {
    let table = try path("/tasks.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "title", type: .text), TableColumn(name: "n", type: .integer),
      TableColumn(name: "score", type: .real), TableColumn(name: "done", type: .boolean),
      TableColumn(name: "data", type: .blob), TableColumn(name: "meta", type: .json),
    ]), in: .shared, acting: .shared)
    return table
  }

  @Test func positionalOpsReturnInsertedIDsInOrder() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let first = try await space.commitRows(
      table, [.insert([.string("a"), .null, .null, .null, .null, .null])], in: .shared, acting: .shared,
    )
    let second = try await space.commitRows(table, [
      .insert([.string("b"), .null, .null, .null, .null, .null]),
      .delete(id: first.ids[0]),
      .insert([.string("c"), .null, .null, .null, .null, .null]),
    ], in: .shared, acting: .shared)
    let rows = try await space.query("SELECT id, title FROM \"/tasks.table\" ORDER BY id")
    #expect(rows.rows == second.ids.enumerated().map { [.integer($1), .text(["b", "c"][$0])] })
    #expect(second.ids.count == 2)
    #expect(second.rev > first.rev)
  }

  @Test func namedInsertChecksEachColumnsType() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let commit = try await space.commitRows(table, edits: [.insert([
      "title": "t", "n": .number(3), "score": .integer(2), "done": true,
      "data": ["blob": "AAE="], "meta": ["json": ["a": [1, 2]]],
    ])], in: .shared, acting: .shared)
    let rows = try await space.query("SELECT id, title, n, score, done, data, meta FROM \"/tasks.table\"")
    let expected: [Cell] = [
      .integer(commit.ids[0]), .text("t"), .integer(3), .real(2), .integer(1), .blob([0, 1]), .text(#"{"a":[1,2]}"#),
    ]
    #expect(rows.rows == [expected])

    let refused: [(String, JSONValue)] = [
      ("title", .integer(1)), ("n", .number(1.5)), ("n", "1"), ("score", "2"), ("done", .integer(1)),
      ("data", "AAE="), ("data", ["blob": "not base64!"]), ("meta", ["a": 1]), ("missing", "x"),
    ]
    for (name, value) in refused {
      await #expect(throws: SpaceError.self, "\(name) = \(value.jsonString())") {
        _ = try await space.commitRows(table, edits: [.insert([name: value])], in: .shared, acting: .shared)
      }
    }
    let count = try await space.query("SELECT count(*) FROM \"/tasks.table\"")
    #expect(count.rows == [[.integer(1)]])
  }

  @Test func jsonColumnTakesRawScalarsAndArrays() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let commit = try await space.commitRows(table, edits: [
      .insert(["meta": "text"]), .insert(["meta": [1, "two"]]), .insert(["meta": .null]),
    ], in: .shared, acting: .shared)
    let rows = try await space.query("SELECT meta FROM \"/tasks.table\" ORDER BY id")
    #expect(commit.ids.count == 3)
    #expect(rows.rows == [[.text(#""text""#)], [.text(#"[1,"two"]"#)], [.null]])
  }

  @Test func namedUpdateKeepsUnnamedFields() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let id = try await space.commitRows(table, edits: [.insert([
      "title": "keep", "n": 1, "data": ["blob": "AAE="], "meta": ["json": ["k": true]],
    ])], in: .shared, acting: .shared).ids[0]
    let update = try await space.commitRows(table, edits: [.update(id: id, ["n": 2, "done": true])], in: .shared, acting: .shared)
    #expect(update.ids.isEmpty)
    let rows = try await space.query("SELECT title, n, done, data, meta FROM \"/tasks.table\"")
    #expect(rows.rows == [[.text("keep"), .integer(2), .integer(1), .blob([0, 1]), .text(#"{"k":true}"#)]])

    await #expect(throws: SpaceError.notFound("/tasks.table#\(id + 1)")) {
      _ = try await space.commitRows(table, edits: [.update(id: id + 1, ["n": 3])], in: .shared, acting: .shared)
    }
  }

  @Test func attributionIsRecordedForItsRevisionOnly() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let plain = try await space.commitRows(table, edits: [.insert(["title": "x"])], in: .shared, acting: .shared)
    let byPage = try await space.commitRows(
      table, edits: [.insert(["title": "y"])], in: .shared, acting: .shared,
      attribution: RevisionAttribution(actor: "ada", via: "/board.html"),
    )
    let token = try await space.fs(.shared, attribution: RevisionAttribution(actor: nil, via: "/p.html")).write(
      "/note.md", bytes("hi"), ifMatch: nil,
    )
    let fileRev = Rev(Int(String(decoding: token.bytes, as: UTF8.self))!)
    let found = try await space.attributions(of: [plain.rev, byPage.rev, fileRev])
    #expect(found == [
      byPage.rev: RevisionAttribution(actor: "ada", via: "/board.html"),
      fileRev: RevisionAttribution(actor: nil, via: "/p.html"),
    ])
  }

  @Test func typedParametersBindBlobsAndRefuseStructures() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    _ = try await space.commitRows(table, edits: [.insert(["title": "a", "data": ["blob": "AAE="]])], in: .shared, acting: .shared)
    let rows = try await space.query(
      "SELECT title FROM \"/tasks.table\" WHERE data = ? AND ? AND ? IS NULL", parameters: [["blob": "AAE="], true, .null],
      as: .shared(.anonymous),
    )
    #expect(rows.rows == [[.text("a")]])
    for bad: JSONValue in [[1], ["json": 1], ["blob": "!"]] {
      await #expect(throws: SpaceError.self) {
        _ = try await space.query("SELECT ?", parameters: [bad], as: .shared(.anonymous))
      }
    }
  }

  @Test func observeBindsParameters() async throws {
    let space = try makeSpace(clock: ImmediateClock())
    let table = try await makeTable(space)
    let results = Collector<Rows>()
    let stream = await space.observeQuery(
      "SELECT title FROM \"/tasks.table\" WHERE n = ?", parameters: [2], throttle: .zero, as: Principal.shared(.anonymous),
    )
    let consumer = Task { do { for try await rows in stream { await results.append(rows) } } catch {} }
    defer { consumer.cancel() }
    _ = await awaitItems(results, atLeast: 1)
    let edits: [RowEdit] = [.insert(["title": "one", "n": 1]), .insert(["title": "two", "n": 2])]
    _ = try await space.commitRows(table, edits: edits, in: .shared, acting: .shared)
    let collected = await awaitItems(results, atLeast: 2)
    let expected: [[[Cell]]] = [[], [[.text("two")]]]
    #expect(collected.map(\.rows) == expected)

    let refused = await space.observeQuery("SELECT ?", parameters: [[1]], throttle: .zero, as: Principal.shared(.anonymous))
    await #expect(throws: SpaceError.self) {
      for try await _ in refused { Issue.record("a refused parameter must not yield") }
    }
  }
}
