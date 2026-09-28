import Foundation
import JSONValue
import SpaceContract
import SpaceTools
import Testing

@Suite struct SpaceVerbTests {
  @Test func historyAndCheckoutRoundTrip() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "v1", context)
    _ = try await seedFile("/a.md", "v2", context)

    let history = try await run("history", .object(["path": "/a.md"]), context, as: HistoryOutput.self)
    #expect(history.entries.map(\.change) == [.write, .write])
    #expect(history.entries.map(\.rev) == history.entries.map(\.rev).sorted())
    #expect(history.entries.allSatisfy { $0.mtime == fixedDate.timeIntervalSince1970 })

    let restored = try await run(
      "checkout", .object(["path": "/a.md", "rev": .integer(first.rev!)]), context, as: CheckoutOutput.self,
    )
    #expect(restored.rev > first.rev!)
    let read = try await run("read", .object(["path": "/a.md"]), context, as: ReadOutput.self)
    #expect(read.content == "v1")
    #expect(read.token == restored.token)

    let after = try await run("history", .object(["path": "/a.md"]), context, as: HistoryOutput.self)
    #expect(after.entries.count == 3)
  }

  @Test func historyRecordsDeletes() async throws {
    let context = try makeContext()
    _ = try await seedFile("/a.md", "x", context)
    _ = try await run("rm", .object(["path": "/a.md"]), context, as: RevisionOutput.self)
    let history = try await run("history", .object(["path": "/a.md"]), context, as: HistoryOutput.self)
    #expect(history.entries.map(\.change) == [.write, .delete])
  }

  @Test func tableCreateWithoutTableSuffixFailsLoudly() async throws {
    let context = try makeContext()
    let bad = await failure(
      "table.create",
      .object(["path": "/data/prs", "header": .object(["columns": .array([
        .object(["name": "title", "type": "string"]),
      ])])]),
      context,
    )
    let error = try #require(bad)
    guard case let .failed(code, message, hint, _) = error else {
      Issue.record("expected .failed, got \(error)")
      return
    }
    #expect(code == .invalidArgument)
    #expect(message.contains("/data/prs"))
    #expect(hint?.contains(".table") == true)
  }

  @Test func tableVerbsWhereATableWasSayItIsGone() async throws {
    let context = try makeContext()
    let columns: JSONValue = .object(["columns": .array([.object(["name": "n", "type": "integer"])])])
    _ = try await run("table.create", .object(["path": "/data/log.table", "header": columns]), context)
    _ = try await run("mv", .object(["from": "/data/log.table", "to": "/data/kept.table"]), context)

    for attempt: (String, JSONValue) in [
      ("table.mutate", .object(["path": "/data/log.table", "ops": .array([.object(["kind": "insert", "values": .array([.integer(1)])])])])),
      ("table.alter", .object(["path": "/data/log.table", "header": columns])),
    ] {
      let error = try #require(await failure(attempt.0, attempt.1, context))
      guard case let .failed(code, message, hint, _) = error else {
        Issue.record("\(attempt.0): expected .failed, got \(error)")
        continue
      }
      #expect(code == .invalidArgument)
      #expect(message == "not a table: /data/log.table")
      #expect(hint?.contains("moved or deleted") == true)
    }
  }

  @Test func tableLifecycleThroughVerbs() async throws {
    let context = try makeContext()
    let created = try await run(
      "table.create",
      .object(["path": "/data/habits.table", "header": .object(["columns": .array([
        .object(["name": "name", "type": "string"]),
        .object(["name": "done", "type": "boolean"]),
      ])])]),
      context,
      as: RevisionOutput.self,
    )
    #expect(created.rev > 0)

    let mutated = try await run(
      "table.mutate",
      .object(["path": "/data/habits.table", "ops": .array([
        .object(["kind": "insert", "values": .array([.string("stretch"), .integer(1)])]),
        .object(["kind": "insert", "values": .array([.string("read"), .integer(0)])]),
      ])]),
      context,
      as: RevisionOutput.self,
    )
    #expect(mutated.rev > created.rev)

    let rows = try await run(
      "query", .object(["sql": "SELECT name, done FROM \"/data/habits.table\" ORDER BY id"]),
      context, as: QueryOutput.self,
    )
    #expect(rows.columns == ["name", "done"])
    #expect(rows.rows == [[.string("stretch"), .bool(true)], [.string("read"), .bool(false)]])

    _ = try await run(
      "table.alter",
      .object(["path": "/data/habits.table", "header": .object(["columns": .array([
        .object(["name": "name", "type": "string"]),
        .object(["name": "done", "type": "boolean"]),
        .object(["name": "note", "type": "string"]),
      ])])]),
      context,
      as: RevisionOutput.self,
    )
    let widened = try await run(
      "query", .object(["sql": "SELECT name, done, note FROM \"/data/habits.table\" ORDER BY id"]),
      context, as: QueryOutput.self,
    )
    #expect(widened.rows[0] == [.string("stretch"), .bool(true), .null])

    _ = try await run(
      "table.mutate",
      .object(["path": "/data/habits.table", "ops": .array([
        .object(["kind": "update", "row": 1, "values": .array([.string("stretch"), .integer(1), .string("daily")])]),
        .object(["kind": "delete", "row": 2]),
      ])]),
      context,
      as: RevisionOutput.self,
    )
    let final = try await run(
      "query", .object(["sql": "SELECT name, note FROM \"/data/habits.table\""]),
      context, as: QueryOutput.self,
    )
    #expect(final.rows == [[.string("stretch"), .string("daily")]])
  }

  @Test func historyCarriesMoveAndCheckoutProvenance() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "v1", context)
    _ = try await seedFile("/a.md", "v2", context)
    _ = try await run(
      "checkout", .object(["path": "/a.md", "rev": .integer(first.rev!)]), context, as: CheckoutOutput.self,
    )
    _ = try await run("mv", .object(["from": "/a.md", "to": "/b.md"]), context, as: MoveOutput.self)

    let history = try await run("history", .object(["path": "/a.md"]), context, as: HistoryOutput.self)
    #expect(history.entries.map(\.change) == [.write, .write, .checkout, .move])
    #expect(history.entries[2].fromRev == first.rev)
    #expect(history.entries[2].to == nil)
    #expect(history.entries[3].to == "/b.md")
    #expect(history.entries[3].fromRev == nil)
    #expect(history.entries.prefix(2).allSatisfy { $0.to == nil && $0.fromRev == nil })
  }

  @Test func jsonAndBooleanCellsRoundTripThroughQuery() async throws {
    let context = try makeContext()
    _ = try await run(
      "table.create",
      .object(["path": "/data/j.table", "header": .object(["columns": .array([
        .object(["name": "payload", "type": "json"]),
        .object(["name": "flag", "type": "boolean"]),
      ])])]),
      context,
      as: RevisionOutput.self,
    )
    let values: [(JSONValue, JSONValue)] = [
      (.object(["k": .integer(1), "s": .string("v")]), .bool(true)),
      (.array([.integer(1), .string("two")]), .bool(false)),
      (.string("plain string"), .bool(true)),
      (.integer(42), .bool(false)),
      (.number(1.5), .bool(true)),
      (.null, .null),
    ]
    _ = try await run(
      "table.mutate",
      .object(["path": "/data/j.table", "ops": .array(values.map { payload, flag in
        .object(["kind": "insert", "values": .array([payload, flag])])
      })]),
      context,
      as: RevisionOutput.self,
    )
    let rows = try await run(
      "query", .object(["sql": "SELECT payload, flag FROM \"/data/j.table\" ORDER BY id"]),
      context, as: QueryOutput.self,
    )
    #expect(rows.rows == values.map { [$0.0, $0.1] })

    let expression = try await run(
      "query", .object(["sql": "SELECT flag + 1, payload FROM \"/data/j.table\" WHERE id = 1"]),
      context, as: QueryOutput.self,
    )
    #expect(expression.rows == [[.integer(2), .object(["k": .integer(1), "s": .string("v")])]])
  }

  @Test func tablesAppearInLsAsTableEntries() async throws {
    let context = try makeContext()
    _ = try await run(
      "table.create",
      .object(["path": "/data/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
      context,
      as: RevisionOutput.self,
    )
    let listed = try await run("ls", .object(["path": "/data"]), context, as: ListOutput.self)
    #expect(listed.entries.map(\.kind) == [.table])
  }

  @Test func queryRejectsMutationsAndForbiddenTables() async throws {
    let context = try makeContext()
    let insert = await failure("query", .object(["sql": "INSERT INTO docs (path, title) VALUES ('/x', 'x')"]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = insert { true } else { false } }())

    let forbidden = await failure("query", .object(["sql": "SELECT * FROM fs_heads"]), context)
    #expect({ if case .failed(code: .invalidArgument, _, _, _) = forbidden { true } else { false } }())
  }

  @Test func newInstantiatesTemplate() async throws {
    let context = try makeContext()
    _ = try await seedFile(
      "/templates/issue.md",
      "---\ntemplate:\n  strategy: incr\n  prefix: ISSUE\n  pad: 4\nkind: issue\n---\n# New issue",
      context,
    )
    let first = try await run(
      "new", .object(["template": "/templates/issue.md", "in": "/issues"]), context, as: NewOutput.self,
    )
    #expect(first.path == "/issues/ISSUE-0001.md")
    let second = try await run(
      "new", .object(["template": "/templates/issue.md", "in": "/issues"]), context, as: NewOutput.self,
    )
    #expect(second.path == "/issues/ISSUE-0002.md")
  }

  @Test func undecodableInputIsDistinguished() async throws {
    let context = try makeContext()
    do {
      _ = try await run("read", .object(["nope": true]), context)
      Issue.record("expected undecodable input")
    } catch let error as ToolRunError {
      #expect({ if case .undecodableInput = error { true } else { false } }())
    }
  }

  @Test func toolboxNamesAreUniqueAndSchemasAreObjects() {
    let names = SpaceToolbox.all.map(\.name)
    #expect(Set(names).count == names.count)
    #expect(SpaceToolbox.all.allSatisfy { $0.inputSchema.object != nil })
    #expect(!names.contains("observe"))
  }
}
