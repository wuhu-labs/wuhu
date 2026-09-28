import Fetch
import FetchSSE
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceServer
import SpaceTools
import Testing

// `/_/space/*`: typed reads, and writes a page makes as its group
// minus admin, admitted only from its own origin with a live read session.
@Suite struct SpaceDataRouteTests {
  static let origin = "https://space.test:5530"
  static let bare = "space.test:5531"

  struct Rig {
    let harness: Harness
    let alice: AccountID
    let aliceGroup: GroupID
    let bob: AccountID
    let bobGroup: GroupID

    var aliceHost: String { "\(aliceGroup.rawValue).space.test:5531" }
    var bobHost: String { "\(bobGroup.rawValue).space.test:5531" }
  }

  func rig(dev: Bool = false, publicRead: Bool = false) async throws -> Rig {
    let harness = try Harness(dev: dev, publicRead: publicRead, origin: Self.origin)
    let alice = try await harness.space.addAccount(kind: .human, name: "alice", admin: true).id
    let bob = try await harness.space.addAccount(kind: .human, name: "bob").id
    let rig = Rig(
      harness: harness, alice: alice, aliceGroup: try await harness.space.ensurePersonalGroup(account: alice),
      bob: bob, bobGroup: try await harness.space.ensurePersonalGroup(account: bob),
    )
    _ = try await run(rig, .shared, "table.create", [
      "path": "/tasks.table", "header": ["columns": [["name": "title", "type": "string"], ["name": "meta", "type": "json"]]],
    ])
    return rig
  }

  @discardableResult
  func run(_ rig: Rig, _ group: GroupID, _ verb: String, _ input: JSONValue) async throws -> JSONValue {
    let context = SpaceToolContext(space: rig.harness.space, principal: Principal(actor: .anonymous, group: group))
    return try await SpaceToolbox.all.first { $0.name == verb }!.run(context, input: input)
  }

  func cookie(_ rig: Rig, _ account: AccountID, _ group: GroupID) async throws -> String {
    "wuhu_read=" + (try await rig.harness.space.createReadSession(
      account: account, group: group, expiresAt: fixedDate.addingTimeInterval(3600),
    )).rawValue
  }

  func get(_ rig: Rig, _ host: String, _ path: String, _ query: [String: String] = [:], cookie: String? = nil) async throws -> Response {
    var components = URLComponents(string: "https://\(host)")!
    components.path = path
    if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var request = Request(url: components.url!, method: .get)
    if let cookie { request.headers[.cookie] = cookie }
    return try await rig.harness.web(request)
  }

  /// A write as the page's own origin sends it, unless told otherwise.
  func post(
    _ rig: Rig, _ host: String, _ path: String, _ body: JSONValue, cookie: String?,
    origin: String? = nil, site: String? = "same-origin", contentType: String = "application/json",
  ) async throws -> Response {
    var request = Request(url: URL(string: "https://\(host)\(path)")!, method: .post)
    request.headers[.origin] = origin ?? "https://\(host)"
    if let site { request.headers[HTTPField.Name("Sec-Fetch-Site")!] = site }
    request.headers[.contentType] = contentType
    if let cookie { request.headers[.cookie] = cookie }
    request.body = .string(body.jsonString())
    return try await rig.harness.web(request)
  }

  func code(_ response: Response) async throws -> String? {
    try await json(response).object?["code"]?.stringValue
  }

  @Test func aPersonalPageWritesSharedTasksAsTheViewerViaThePage() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let response = try await post(r, r.aliceHost, "/_/space/rows", [
      "path": "wuhu://shared.localspace/tasks.table",
      "ops": [["insert": ["title": "ship", "meta": ["json": ["n": 1]]]], ["insert": ["title": "test"]]],
      "page": "/apps/dash%20board.html",
    ], cookie: alices)
    #expect(response.status == .ok)
    let output = try JSONValueDecoder().decode(TableMutateOutput.self, from: try await json(response))
    #expect(output.ids == [1, 2])

    let history = try JSONValueDecoder().decode(HistoryOutput.self, from: try await run(r, .shared, "history", ["path": "/tasks.table"]))
    let entry = try #require(history.entries.first { $0.rev == output.rev })
    let persona = try await r.harness.space.persona(account: r.alice)?.name ?? r.alice.rawValue
    #expect(entry.by == persona)
    #expect(entry.via == "/apps/dash board.html")
    #expect(history.entries.filter { $0.via != nil }.count == 1)
  }

  @Test func aPageCannotPatchSharedAgentsMDEvenForAnAdmin() async throws {
    let r = try await rig()
    #expect(try await r.harness.space.isHumanAdmin(r.alice, of: .shared))
    let written = try await run(r, .shared, "write", ["path": "/AGENTS.md", "content": "---\nk: 1\n---\nrules\n"])
    let token = try #require(written.object?["token"])
    let alices = try await cookie(r, r.alice, .shared)
    let refused = try await post(r, Self.bare, "/_/space/attributes", [
      "path": "/AGENTS.md", "set": ["k": 2], "ifMatch": token, "page": "/p.html",
    ], cookie: alices)
    #expect(refused.status == .forbidden)
    #expect(try await code(refused) == "unauthorized")

    let plan = try await run(r, .shared, "write", ["path": "/plan.md", "content": "---\nk: 1\n---\n"])
    let patched = try await post(r, Self.bare, "/_/space/attributes", [
      "path": "/plan.md", "set": ["k": 2], "ifMatch": try #require(plan.object?["token"]), "page": "/p.html",
    ], cookie: alices)
    #expect(patched.status == .ok)
    let read = try JSONValueDecoder().decode(ReadOutput.self, from: try await run(r, .shared, "read", ["path": "/plan.md"]))
    #expect(read.content == "---\nk: 2\n---\n")
  }

  @Test func aStaleIfMatchIsA409CarryingTheCurrentToken() async throws {
    let r = try await rig()
    let first = try await run(r, r.aliceGroup, "write", ["path": "/a.md", "content": "---\nk: 1\n---\n"])
    let second = try await run(r, r.aliceGroup, "write", ["path": "/a.md", "content": "---\nk: 2\n---\n"])
    let response = try await post(r, r.aliceHost, "/_/space/attributes", [
      "path": "/a.md", "set": ["k": 3], "ifMatch": try #require(first.object?["token"]), "page": "/p.html",
    ], cookie: try await cookie(r, r.alice, r.aliceGroup))
    #expect(response.status == .conflict)
    let body = try await json(response)
    #expect(body.object?["code"] == "conflict")
    #expect(body.object?["token"] == second.object?["token"])
  }

  // Alice's HTML in a DM opens on Bob's host with Bob's cookie, but it is
  // message content: sandboxed into an opaque origin, its writes send
  // `Origin: null`, and naming a page of Bob's does not help it.
  @Test func anAttachmentIsSandboxedSoItCannotWriteTheViewersGroup() async throws {
    let r = try await rig()
    let space = r.harness.space
    _ = try await run(r, r.bobGroup, "table.create", [
      "path": "/private.table", "header": ["columns": [["name": "title", "type": "string"]]],
    ])
    let dm = try await space.sessions.createConversation(members: [r.alice.rawValue, r.bob.rawValue], in: r.aliceGroup)
    let posted = try await space.sessions.post(
      .conversation(dm), messageID: MessageID("m1"),
      sender: Sender(id: r.alice.rawValue, timeZone: TimeZone(identifier: "UTC")!),
      content: .init(text: "open me"),
      uploads: [AttachmentUpload(name: "x.html", bytes: Array("<html><head></head><body>x</body></html>".utf8))],
      acting: Principal(actor: .person(persona: r.alice.rawValue, account: r.alice), group: r.aliceGroup),
    )
    let page = try #require(posted.message.content.attachments.first?.path)
    let bobs = try await cookie(r, r.bob, r.bobGroup)
    let csp = HTTPField.Name("Content-Security-Policy")!
    let opened = try await get(r, r.bobHost, page, cookie: bobs)
    #expect(opened.status == .ok)
    let sandbox = try #require(opened.headers[csp])
    #expect(sandbox.hasPrefix("sandbox allow-scripts; frame-ancestors 'self' "))
    #expect(!sandbox.contains("allow-same-origin"))
    #expect(try await opened.text() == "<html><head></head><body>x</body></html>")
    let atHome = try await get(r, r.aliceHost, page, cookie: try await cookie(r, r.alice, r.aliceGroup))
    #expect(atHome.headers[csp]?.hasPrefix("sandbox allow-scripts; ") == true)

    let forged: JSONValue = ["path": "/private.table", "ops": [["insert": ["title": "planted"]]], "page": "/apps/mine.html"]
    for site in ["cross-site", "same-origin"] {
      let refused = try await post(r, r.bobHost, "/_/space/rows", forged, cookie: bobs, origin: "null", site: site)
      #expect(refused.status == .forbidden)
      #expect(try await code(refused) == "crossOrigin")
    }
    let patch: JSONValue = ["path": "/notes.md", "set": ["k": 1], "ifMatch": "x", "page": "/apps/mine.html"]
    let patched = try await post(r, r.bobHost, "/_/space/attributes", patch, cookie: bobs, origin: "null")
    #expect(try await code(patched) == "crossOrigin")
    let count = try await space.query("SELECT count(*) FROM \"/private.table\"", as: Principal(actor: .anonymous, group: r.bobGroup))
    #expect(count.rows == [[.integer(0)]])

    _ = try await run(r, r.bobGroup, "write", ["path": "/apps/mine.html", "content": "<html><head></head><body>mine</body></html>"])
    let mine = try await get(r, r.bobHost, "/apps/mine.html", cookie: bobs)
    #expect(mine.status == .ok)
    #expect(mine.headers[csp]?.hasPrefix("frame-ancestors ") == true)
    #expect(try await mine.text().contains("wuhu:space"))
    #expect(try await post(r, r.bobHost, "/_/space/rows", forged, cookie: bobs).status == .ok)
  }

  @Test func twoOpsOnOneRowAreRefusedWithNothingWritten() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, .shared)
    let seeded = try await post(r, Self.bare, "/_/space/rows", [
      "path": "/tasks.table", "ops": [["insert": ["title": "a"]]], "page": "/p.html",
    ], cookie: alices)
    #expect(seeded.status == .ok)
    let refused = try await post(r, Self.bare, "/_/space/rows", [
      "path": "/tasks.table", "ops": [["update": 1, "set": ["title": "b"]], ["update": 1, "set": ["meta": ["json": 1]]]],
      "page": "/p.html",
    ], cookie: alices)
    #expect(refused.status == .badRequest)
    let body = try await json(refused)
    #expect(body.object?["code"] == "invalidArgument")
    #expect(body.object?["message"]?.stringValue?.contains("both touch row 1") == true)
    let rows = try await r.harness.space.query("SELECT title, meta FROM \"/tasks.table\"", as: .shared(.anonymous))
    #expect(rows.rows == [[.text("a"), .null]])
  }

  @Test func writesComeOnlyFromThePagesOwnOriginWithALiveSession() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let body: JSONValue = ["path": "/notes.md", "set": ["k": 1], "ifMatch": "x", "page": "/p.html"]
    let sibling = try await post(
      r, r.aliceHost, "/_/space/attributes", body, cookie: alices, origin: "https://\(r.bobHost)", site: "same-site",
    )
    #expect(sibling.status == .forbidden)
    #expect(try await code(sibling) == "crossOrigin")
    let sameOriginClaim = try await post(
      r, r.aliceHost, "/_/space/rows", ["path": "/t.table", "ops": [], "page": "/p.html"], cookie: alices,
      origin: "https://\(r.bobHost)",
    )
    #expect(try await code(sameOriginClaim) == "crossOrigin")
    #expect(try await code(post(r, r.aliceHost, "/_/space/attributes", body, cookie: alices, site: "same-site")) == "crossOrigin")
    #expect(try await code(post(r, r.aliceHost, "/_/space/attributes", body, cookie: alices, site: nil)) == "crossOrigin")
    #expect(try await post(r, r.aliceHost, "/_/space/attributes", body, cookie: nil).status == .unauthorized)
    #expect(try await post(r, r.aliceHost, "/_/space/attributes", body, cookie: alices, contentType: "text/plain").status == .unsupportedMediaType)
    for page: JSONValue in [.null, "p.html", "https://elsewhere/p.html", "//elsewhere/p.html", 3] {
      var fields = body.object!
      fields["page"] = page
      let response = try await post(r, r.aliceHost, "/_/space/attributes", .object(fields), cookie: alices)
      #expect(response.status == .badRequest, "page \(page)")
    }
    var get = Request(url: URL(string: "https://\(r.aliceHost)/_/space/rows")!, method: .get)
    get.headers[.cookie] = alices
    #expect(try await r.harness.web(get).status == .methodNotAllowed)
  }

  @Test func aPublicReadVisitorReadsButNeverWrites() async throws {
    let r = try await rig(publicRead: true)
    let query = try await get(r, Self.bare, "/_/space/query", ["sql": "SELECT title FROM \"/tasks.table\""])
    #expect(query.status == .ok)
    let write = try await post(r, Self.bare, "/_/space/rows", [
      "path": "/tasks.table", "ops": [["insert": ["title": "x"]]], "page": "/p.html",
    ], cookie: nil)
    #expect(write.status == .unauthorized)
    let rows = try await r.harness.space.query("SELECT count(*) FROM \"/tasks.table\"", as: .shared(.anonymous))
    #expect(rows.rows == [[.integer(0)]])
  }

  @Test func aDevSeatPageWritesWithNoActor() async throws {
    let r = try await rig(dev: true)
    let response = try await post(r, Self.bare, "/_/space/rows", [
      "path": "/tasks.table", "ops": [["insert": ["title": "x"]]], "page": "/p.html",
    ], cookie: nil)
    #expect(response.status == .ok)
    let history = try JSONValueDecoder().decode(HistoryOutput.self, from: try await run(r, .shared, "history", ["path": "/tasks.table"]))
    let entry = try #require(history.entries.first { $0.via != nil })
    #expect(entry.via == "/p.html")
    #expect(entry.by == nil)
  }

  @Test func queryIsTypedAndBindsParamsWhileLegacyQueryIsUnchanged() async throws {
    let r = try await rig()
    try await run(r, .shared, "table.mutate", [
      "path": "/tasks.table", "ops": [["kind": "insert", "values": ["a", ["k": 1]]], ["kind": "insert", "values": ["b", .null]]],
    ])
    let alices = try await cookie(r, r.alice, .shared)
    let sql = "SELECT title, meta FROM \"/tasks.table\" WHERE title = ?"
    let typed = try await get(r, Self.bare, "/_/space/query", ["sql": sql, "params": "[\"a\"]"], cookie: alices)
    #expect(typed.status == .ok)
    #expect(try await json(typed) == ["columns": ["title", "meta"], "rows": [["a", ["json": ["k": 1]]]]])

    let legacySQL = "SELECT title, meta FROM \"/tasks.table\" WHERE title = 'a'"
    let legacy = try await get(r, Self.bare, "/_/query", ["sql": legacySQL], cookie: alices)
    #expect(try await json(legacy) == ["columns": ["title", "meta"], "rows": [["a", ["k": 1]]]])

    for params in ["{}", "1", "[", "[{\"x\":1}]"] {
      let bad = try await get(r, Self.bare, "/_/space/query", ["sql": sql, "params": params], cookie: alices)
      #expect(bad.status == .badRequest, "params \(params)")
    }
  }

  @Test func observeDeliversANewTypedSnapshotAfterAPageWrite() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, .shared)
    let observe = try await get(r, Self.bare, "/_/space/observe", [
      "sql": "SELECT title, meta FROM \"/tasks.table\" WHERE title <> ? ORDER BY id", "params": "[\"skip\"]",
    ], cookie: alices)
    #expect(observe.status == .ok)
    var snapshots: [JSONValue] = []
    for try await frame in observe.sse() {
      snapshots.append(try #require(JSONValue.parse(frame.data)))
      if snapshots.count == 1 {
        let write = try await post(r, Self.bare, "/_/space/rows", [
          "path": "/tasks.table", "ops": [["insert": ["title": "skip"]], ["insert": ["title": "new", "meta": ["json": [1]]]]],
          "page": "/p.html",
        ], cookie: alices)
        #expect(write.status == .ok)
      }
      if snapshots.count == 2 { break }
    }
    #expect(snapshots == [
      ["columns": ["title", "meta"], "rows": []],
      ["columns": ["title", "meta"], "rows": [["new", ["json": [1]]]]],
    ])
  }

  // A statement refused before the stream opens answers as /_/space/query
  // answers it; legacy /_/observe keeps its flat 422.
  @Test func observeRefusesBeforeStreamingWithTheQueryRoutesStatus() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let cases: [(sql: String, params: String, status: Status, code: String)] = [
      ("SELECT ?", "[{\"x\":1}]", .badRequest, "invalidArgument"),
      ("DELETE FROM \"/tasks.table\"", "[]", .badRequest, "invalidArgument"),
      ("SELECT * FROM \"/missing.table\"", "[]", .notFound, "notFound"),
      ("SELECT * FROM \"wuhu://\(r.bobGroup.rawValue).localspace/tasks.table\"", "[]", .notFound, "notFound"),
    ]
    for (sql, params, status, expected) in cases {
      let observe = try await get(r, r.aliceHost, "/_/space/observe", ["sql": sql, "params": params], cookie: alices)
      let query = try await get(r, r.aliceHost, "/_/space/query", ["sql": sql, "params": params], cookie: alices)
      #expect([observe.status, query.status] == [status, status], "\(sql)")
      #expect(try await code(observe) == expected, "\(sql)")
    }
    let legacy = try await get(r, r.aliceHost, "/_/observe", ["sql": "SELECT * FROM \"/missing.table\""], cookie: alices)
    #expect(legacy.status == .unprocessableContent)
  }

  // Without `from`, the stream opens on the head revision, so a client that
  // drops before any event resumes from there; file events follow unchanged.
  @Test func watchOpensOnTheHeadRevisionAndSeesAnAttributePatchAsAWrite() async throws {
    let r = try await rig()
    let written = try await run(r, .shared, "write", ["path": "/notes/a.md", "content": "---\nk: 1\n---\n"])
    let head = try #require(written.object?["rev"]?.intValue)
    let alices = try await cookie(r, r.alice, .shared)
    let watch = try await get(r, Self.bare, "/_/space/watch", ["glob": "/notes/**"], cookie: alices)
    #expect(watch.status == .ok)
    var frames = watch.sse().makeAsyncIterator()
    let opening = try #require(try await frames.next())
    #expect(opening.event == "head")
    #expect(JSONValue.parse(opening.data) == ["rev": .integer(head)])

    let patch = try await post(r, Self.bare, "/_/space/attributes", [
      "path": "/notes/a.md", "set": ["k": 2], "ifMatch": try #require(written.object?["token"]), "page": "/p.html",
    ], cookie: alices)
    #expect(patch.status == .ok)
    let frame = try #require(try await frames.next())
    #expect(frame.event == "message")
    let event = try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data)))
    guard case let .write(path, rev, entry) = event else {
      Issue.record("expected a write, got \(event)")
      return
    }
    #expect(path == "/notes/a.md")
    #expect(rev > head)
    #expect(entry == .file)
    let attributes = try await get(r, Self.bare, "/_/space/attributes", ["path": "/notes/a.md"], cookie: alices)
    #expect(try await json(attributes).object?["attributes"] == ["k": 2])

    // With `from` the replay comes first, and legacy /_/observe never sends a head frame.
    for (path, query) in [
      ("/_/space/watch", ["glob": "/notes/**", "from": String(head)]),
      ("/_/observe", ["glob": "/notes/**", "from": String(head)]),
      ("/_/observe", ["glob": "/notes/**"]),
    ] {
      if query["from"] == nil {
        try await run(r, .shared, "write", ["path": "/notes/b.md", "content": "b"])
      }
      let response = try await get(r, Self.bare, path, query, cookie: alices)
      if query["from"] == nil {
        try await run(r, .shared, "write", ["path": "/notes/c.md", "content": "c"])
      }
      var iterator = response.sse().makeAsyncIterator()
      let first = try #require(try await iterator.next())
      #expect(first.event == "message", "\(path) \(query)")
      #expect(JSONValue.parse(first.data)?.object?["kind"] == "write", "\(path) \(query)")
    }
  }

  @Test func pagesGetTheImportMapAtTheStartOfHeadAndATagThatCarriesIt() async throws {
    let r = try await rig(dev: true)
    try await run(r, .shared, "write", [
      "path": "/page.html", "content": "<!doctype html><html><HEAD lang=en><title>t</title></HEAD><header></header><body>b</body></html>",
    ])
    try await run(r, .shared, "write", ["path": "/bare.html", "content": "<!DOCTYPE html>\n<p>no head</p>"])
    let map = #"<script type="importmap">{"imports":{"wuhu:space":"/_/space.js"}}</script>"#
    let page = try await get(r, Self.bare, "/page.html")
    let text = try await page.text()
    #expect(text.hasPrefix("<!doctype html><html><HEAD lang=en>" + map + "<title>t</title>"))
    #expect(text.hasSuffix(#"<script type="module" src="/_/shell.js"></script></body></html>"#))
    let tag = try #require(page.headers[.eTag])
    #expect(tag.range(of: #"^"[^"]+-shell-[0-9a-f]{12}"$"#, options: .regularExpression) != nil)

    #expect(try await get(r, Self.bare, "/bare.html").text().hasPrefix("<!DOCTYPE html>" + map + "\n<p>no head</p>"))

    let core = try await get(r, Self.bare, "/_/space-core.js")
    #expect(core.status == .ok)
    #expect(core.headers[.cacheControl] == "no-cache")
    #expect(try await core.text().contains("export function createSpace"))
  }
}
