import JSONValue
import OrderedCollections
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import Testing

@Suite struct DataVerbTests {
  func code(_ error: ToolRunError?) -> ErrorCode? {
    if case let .failed(code, _, _, _)? = error { code } else { nil }
  }

  @Test func attributesReadAndPatchKeepTheRestOfTheFile() async throws {
    let context = try makeContext()
    let source = "---\n# owner comment\ntitle: 'Plan'\ndraft: true\n---\nbody\n"
    _ = try await seedFile("/notes/plan.md", source, context)
    let read = try await run("attributes.read", ["path": "/notes/plan.md"], context, as: AttributesReadOutput.self)
    #expect(read.attributes == ["title": "Plan", "draft": true])

    let patched = try await run(
      "attributes.patch",
      ["path": "/notes/plan.md", "set": ["status": "done"], "remove": ["draft"], "ifMatch": .string(read.token)],
      context, as: AttributesPatchOutput.self,
    )
    let file = try await run("read", ["path": "/notes/plan.md"], context, as: ReadOutput.self)
    #expect(file.content == "---\n# owner comment\ntitle: 'Plan'\nstatus: done\n---\nbody\n")
    #expect(file.token == patched.token)
    let docs = try await context.space.query("SELECT status FROM docs WHERE path = '/notes/plan.md'", as: .shared(.anonymous))
    #expect(docs.rows == [[.text("done")]])
  }

  @Test func staleIfMatchIsAConflictCarryingTheCurrentToken() async throws {
    let context = try makeContext()
    let first = try await seedFile("/a.md", "---\nk: 1\n---\n", context)
    let second = try await seedFile("/a.md", "---\nk: 2\n---\n", context)
    let error = await failure("attributes.patch", ["path": "/a.md", "set": ["k": 3], "ifMatch": .string(first.token)], context)
    #expect(error == .failed(code: .conflict, message: "version mismatch: /a.md", hint: "changed since you read it — re-read", token: second.token))
    #expect(error?.payload.object?["token"] == .string(second.token))
    let file = try await run("read", ["path": "/a.md"], context, as: ReadOutput.self)
    #expect(file.content == "---\nk: 2\n---\n")
  }

  @Test func patchRefusesWhatItCannotKeepAndWhatIsNotMarkdown() async throws {
    let context = try makeContext()
    let anchored = try await seedFile("/a.md", "---\nbase: &b 1\ncopy: *b\n---\n", context)
    #expect(code(await failure("attributes.patch", ["path": "/a.md", "set": ["x": 1], "ifMatch": .string(anchored.token)], context)) == .unsupported)
    let malformed = try await seedFile("/m.md", "---\nk: [\n---\n", context)
    #expect(code(await failure("attributes.read", ["path": "/m.md"], context)) == .invalidArgument)
    #expect(code(await failure("attributes.patch", ["path": "/m.md", "set": ["x": 1], "ifMatch": .string(malformed.token)], context)) == .invalidArgument)
    let page = try await seedFile("/p.html", "<p>hi</p>", context)
    #expect(code(await failure("attributes.patch", ["path": "/p.html", "set": ["x": 1], "ifMatch": .string(page.token)], context)) == .invalidArgument)
    #expect(code(await failure("attributes.patch", ["path": "/a.md", "set": [1], "ifMatch": .string(anchored.token)], context)) == .invalidArgument)
  }

  @Test func tableMutateReturnsInsertedIDs() async throws {
    let context = try makeContext()
    _ = try await run("table.create", ["path": "/t.table", "header": ["columns": [["name": "n", "type": "integer"]]]], context)
    let output = try await run(
      "table.mutate",
      ["path": "/t.table", "ops": [["kind": "insert", "values": [1]], ["kind": "insert", "values": [2]]]],
      context, as: TableMutateOutput.self,
    )
    let rows = try await context.space.query("SELECT id FROM \"/t.table\" ORDER BY id", as: .shared(.anonymous))
    #expect(rows.rows == output.ids.map { [.integer(Int64($0))] })
    #expect(output.ids.count == 2)
  }

  @Test func namedOpsTouchEachRowAtMostOnce() throws {
    let twice: [JSONValue] = [
      [["update": 7, "set": ["a": 1]], ["update": 7, "set": ["b": 2]]],
      [["update": 7, "set": ["a": 1]], ["delete": 7]],
      [["delete": 7], ["insert": ["a": 1]], ["delete": 7.0]],
    ]
    for ops in twice {
      #expect(throws: ToolRunError.failed(
        code: .invalidArgument,
        message: "ops[0] and ops[\(ops.array!.count - 1)] both touch row 7; one call touches each row at most once, so merge its fields into one update",
        hint: nil,
      )) { try RowEdit.parse(ops) }
    }
    let distinct = try RowEdit.parse([["insert": ["a": 1]], ["insert": ["a": 2]], ["update": 7, "set": [:]], ["delete": 8]])
    #expect(distinct.count == 4)
  }

  @Test func typedQueryWrapsJSONAndBlobsAndBindsParameters() async throws {
    let context = try makeContext()
    let header = SpaceCore.TableHeader(columns: [
      TableColumn(name: "meta", type: .json), TableColumn(name: "done", type: .boolean), TableColumn(name: "data", type: .blob),
    ])
    _ = try await context.space.createTable(try SpacePath(validating: "/t.table"), header: header, in: .shared, acting: .shared)
    _ = try await context.commitRows("/t.table", edits: [
      .insert(["meta": ["json": "text"], "done": true, "data": ["blob": "AAE="]]), .insert(["meta": .null, "done": false]),
    ])
    let output = try await context.typedQuery("SELECT meta, done, data, done OR 0 AS raw FROM \"/t.table\" WHERE done = ?", parameters: [true])
    #expect(output == [
      "columns": ["meta", "done", "data", "raw"],
      "rows": [[["json": "text"], true, ["blob": "AAE="], 1]],
    ])
    let nulls = try await context.typedQuery("SELECT meta FROM \"/t.table\" WHERE NOT done", parameters: [])
    #expect(nulls == ["columns": ["meta"], "rows": [[.null]]])
  }

  @Test func historyShowsTheViewerViaThePage() async throws {
    let context = try makeContext()
    let account = try await context.space.addAccount(kind: .human, name: "ada")
    let group = try await context.space.ensurePersonalGroup(account: account.id)
    let page = SpaceToolContext(
      space: context.space, principal: Principal(actor: .person(persona: "ada", account: account.id), group: group),
      page: try SpacePath(validating: "/apps/tasks.html"),
    )
    _ = try await run("table.create", ["path": "/tasks.table", "header": ["columns": [["name": "title", "type": "string"]]]], context)
    let commit = try await page.commitRows("wuhu://shared.localspace/tasks.table", edits: [.insert(["title": "from ada's page"])])
    let history = try await run("history", ["path": "/tasks.table"], context, as: HistoryOutput.self)
    let entry = try #require(history.entries.first { $0.rev == commit.rev.value })
    #expect(entry.by == "ada")
    #expect(entry.via == "/apps/tasks.html")
    #expect(history.entries.filter { $0.via != nil }.count == 1)
    let schema = try #require(ContractSchemas.all.first { $0.name == "HistoryOutput" }?.schema)
    #expect(schemaIssues(try await run("history", ["path": "/tasks.table"], context), schema: schema) == [])
  }

  @Test func aPageWritesAsANonAdminMemberOfItsGroup() async throws {
    let context = try makeContext()
    let space = context.space
    let admin = try await space.addAccount(kind: .human, name: "root", admin: true)
    #expect(try await space.isHumanAdmin(admin.id, of: .shared))
    let home = try await space.ensurePersonalGroup(account: admin.id)
    let other = try await space.addAccount(kind: .human, name: "bob")
    let sibling = try await space.ensurePersonalGroup(account: other.id)
    let actor = Actor.person(persona: "root", account: admin.id)
    let person = SpaceToolContext(space: space, principal: Principal(actor: actor, group: home))
    let pageAt: (GroupID) throws -> SpaceToolContext = { group in
      SpaceToolContext(space: space, principal: Principal(actor: actor, group: group), page: try SpacePath(validating: "/p.html"))
    }
    let sharedLayer = try await seedFile("/AGENTS.md", "---\nk: 1\n---\n", context)
    let homeLayer = try await seedFile("wuhu://\(home.rawValue).localspace/AGENTS.md", "---\nk: 1\n---\n", person)
    let sessionHome = try await seedFile("/_/sessions/some-session-id/notes.md", "---\nk: 1\n---\n", context)
    let siblingFile = try await seedFile("/n.md", "---\nk: 1\n---\n", SpaceToolContext(space: space, principal: Principal(actor: .anonymous, group: sibling)))

    func patch(_ context: SpaceToolContext, _ path: String, _ token: String) async -> ToolRunError? {
      await failure("attributes.patch", ["path": .string(path), "set": ["k": 2], "ifMatch": .string(token)], context)
    }
    #expect(await patch(person, "wuhu://shared.localspace/AGENTS.md", sharedLayer.token) == nil)
    let current = try await run("read", ["path": "/AGENTS.md"], context, as: ReadOutput.self).token
    #expect(code(await patch(try pageAt(home), "wuhu://shared.localspace/AGENTS.md", current)) == .unauthorized)
    #expect(code(await patch(try pageAt(.shared), "/AGENTS.md", current)) == .unauthorized)
    #expect(code(await patch(try pageAt(.shared), "/_/sessions/some-session-id/notes.md", sessionHome.token)) == .unauthorized)
    #expect(code(await patch(try pageAt(home), "wuhu://\(sibling.rawValue).localspace/n.md", siblingFile.token)) == .notFound)
    #expect(await patch(try pageAt(home), "/AGENTS.md", homeLayer.token) == nil)

    let skills = SpaceTools.SpaceToolContext(space: space, principal: Principal(actor: actor, group: home), page: try SpacePath(validating: "/p.html"))
    await #expect(throws: SpaceError.self) {
      _ = try await skills.commitRows("wuhu://shared.localspace/.agents/skills/x.table", edits: [])
    }
  }
}
