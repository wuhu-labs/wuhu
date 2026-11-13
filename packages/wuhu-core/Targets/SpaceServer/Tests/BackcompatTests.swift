import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import FetchSSE
import Foundation
import JSONValue
import LoopCore
import Scratch
import SessionDomain
@testable import SpaceCore
import SpaceTools
import Synchronization
import Testing

// The SQL today's clients send — the app, the SPA, custom sidebars, the CLI —
// and the errors they read, answered against Backcompat/space.sqlite with an
// ordinary account. Wuhu45MigrationTests retains the pre-ledger database.
// Re-record only from a known-good engine: `bazel test //packages/wuhu-core:SpaceServerTests
// --test_env=BACKCOMPAT_RECORD=1 --test_filter=BackcompatTests`, then copy
// space.sqlite and goldens.json out of the test's undeclared outputs.
@Suite(.deterministicDependencies) struct BackcompatTests {
  static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Backcompat")
  static let goldens = try? JSONDecoder().decode(Goldens.self, from: Data(contentsOf: folder.appending(path: "goldens.json")))

  @Test func everyProbeHasAGolden() throws {
    let goldens = try #require(Self.goldens)
    #expect(Backcompat.probes(goldens.meta).keys.sorted() == goldens.answers.keys.sorted())
  }

  @Test(arguments: goldens?.answers.keys.sorted() ?? [])
  func todaysClientSQLAnswersByteForByte(_ name: String) async throws {
    let goldens = try #require(Self.goldens)
    let probe = try #require(Backcompat.probes(goldens.meta)[name])
    let answer = try await Backcompat.answer(probe, fixture: Self.folder.appending(path: "space.sqlite"), meta: goldens.meta)
    #expect(answer == goldens.answers[name])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKCOMPAT_RECORD"] != nil))
  func record() async throws {
    let outputs = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"]))
    let fixture = outputs.appending(path: "space.sqlite")
    let meta = try await Backcompat.buildFixture(at: fixture)
    let goldens = try await Goldens(meta: meta, answers: Backcompat.answers(fixture: fixture, meta: meta))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(goldens) + Data("\n".utf8)).write(to: outputs.appending(path: "goldens.json"))
  }
}

struct Goldens: Codable {
  // What the fixture minted and a client would already hold.
  struct Meta: Codable {
    let box: String
    let device: String
    let cookie: String
  }

  let meta: Meta
  let answers: [String: String]
}

enum Backcompat {
  enum Mutation {
    case readTheBox
    case insertATask
    case writeADoc
  }

  enum Probe {
    case tool(String)
    case observe(String, then: Mutation? = nil)
    case webQuery(String)
    case webObserve(String)
  }

  static func probes(_ meta: Goldens.Meta) -> [String: Probe] {
    let appSessions = """
    SELECT id, title, lifecycle, hold, work, executor, executor_config, error_message, kind, parent,
      EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.recipient = viewer() AND n.kind = 'conversation_message' AND n.source = sessions.id
          AND n.n > COALESCE((SELECT last_read_n FROM watermarks w WHERE w.identity = viewer() AND w.source = sessions.id), 0)
      ) AS has_unread
    FROM sessions ORDER BY last_activity_at DESC
    """
    let appUnread = """
    SELECT COUNT(DISTINCT n.source) FROM notifications n
    JOIN sessions s ON s.id = n.source AND s.kind = 'agent' AND s.lifecycle != 'archived'
    WHERE n.recipient = viewer() AND n.kind = 'conversation_message'
      AND n.n > COALESCE((SELECT last_read_n FROM watermarks w WHERE w.identity = n.recipient AND w.source = n.source), 0)
    """
    let deviceCommands = """
    SELECT n, payload, created_at FROM device_commands
    WHERE device_id = '\(meta.device)'
      AND created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-60 seconds')
    ORDER BY n
    """
    let spaSessions = """
    SELECT id, title, hold, work, lifecycle, kind, parent,
      EXISTS (SELECT 1 FROM notifications n
        WHERE n.recipient = viewer() AND n.kind = 'conversation_message' AND n.source = sessions.id
          AND n.n > COALESCE((SELECT last_read_n FROM watermarks w
            WHERE w.identity = viewer() AND w.source = sessions.id), 0)) AS has_unread,
      executor, executor_config, last_activity_at, error_message, created_by
    FROM sessions ORDER BY last_activity_at DESC
    """
    let docMeta = """
    SELECT docs.kind, docs.status, doc_custom_attrs.name, doc_custom_attrs.value
    FROM docs LEFT JOIN doc_custom_attrs ON doc_custom_attrs.path = docs.path
    WHERE docs.path = '/notes/a.md'
    ORDER BY doc_custom_attrs.name, doc_custom_attrs.ord
    """
    let sidebarTree = """
    WITH RECURSIVE tree(id, parent_id, title) AS (
      SELECT id, NULL, title FROM sessions WHERE parent IS NULL AND kind = 'agent'
      UNION ALL SELECT s.id, s.parent, s.title FROM sessions s JOIN tree t ON s.parent = t.id WHERE s.lifecycle <> 'archived'
    ) SELECT id, parent_id, title, '/_/sessions/' || id AS destination, 0 AS sort_order FROM tree ORDER BY title
    """
    let sidebarAttrs = """
    SELECT d.path AS id, json_extract(p.value, '$') AS parent_id, COALESCE(json_extract(t.value, '$'), d.title) AS title,
      d.path AS destination, json_extract(s.value, '$') AS sort_order
    FROM docs d LEFT JOIN doc_custom_attrs p ON p.path = d.path AND p.name = 'parent'
      LEFT JOIN doc_custom_attrs t ON t.path = d.path AND t.name = 'title'
      LEFT JOIN doc_custom_attrs s ON s.path = d.path AND s.name = 'sort'
    WHERE d.path LIKE '/notes/%' ORDER BY sort_order, d.path
    """
    var probes: [String: Probe] = [
      "observe/app-sessions": .observe(appSessions, then: .readTheBox),
      "observe/app-unread": .observe(appUnread, then: .readTheBox),
      "observe/app-tasks": .observe("SELECT * FROM \"/tasks.table\"", then: .insertATask),
      "observe/app-device-commands": .observe(deviceCommands),
      "observe/spa-sessions": .observe(spaSessions, then: .readTheBox),
      "observe/spa-device-commands": .observe(deviceCommands),
      "observe/doc-meta": .observe(docMeta),
      "observe/sidebar-tree": .observe(sidebarTree),
      "observe/sidebar-attrs": .observe(sidebarAttrs, then: .writeADoc),
      "observe/cli-docs": .observe("SELECT path, title FROM docs ORDER BY path", then: .writeADoc),
      "observe/viewer": .observe("SELECT viewer() AS v"),
      "observe/error-forbidden": .observe("SELECT * FROM fs_heads"),
      "observe/error-unknown": .observe("SELECT * FROM nope"),
      "observe/error-write": .observe("DELETE FROM docs"),
      "tool/cli-docs": .tool("SELECT path, title FROM docs ORDER BY path"),
      "tool/cli-tasks": .tool("SELECT * FROM \"/tasks.table\""),
      "tool/app-unread": .tool(appUnread),
      "tool/viewer": .tool("SELECT viewer() AS v"),
      "tool/values": .tool("VALUES (1, 'a', NULL, 2.5, x'00ff')"),
      "tool/cte": .tool("WITH x(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM x WHERE n < 3) SELECT n FROM x"),
      "tool/json-each": .tool("SELECT key, value, type FROM json_each('[1,\"a\",null,{\"b\":true}]')"),
      "tool/json-tree": .tool("SELECT d.path, j.fullkey, j.atom FROM doc_custom_attrs d, json_tree(d.value) j ORDER BY d.path, d.name, d.ord, j.id"),
      "tool/count": .tool("SELECT count(*) AS n, count(DISTINCT kind) AS kinds FROM sessions"),
      "tool/lowercase-keyword": .tool("select title from docs where path = '/notes/b.md'"),
      "tool/error-forbidden": .tool("SELECT * FROM fs_heads"),
      "tool/error-forbidden-many": .tool("SELECT * FROM fs_heads JOIN bucket_objects JOIN docs"),
      "tool/error-master": .tool("SELECT * FROM sqlite_master"),
      "tool/error-unknown": .tool("SELECT * FROM nope"),
      "tool/error-write": .tool("DELETE FROM docs"),
      "tool/error-pragma": .tool("PRAGMA table_list"),
      "tool/error-syntax": .tool("SELEC 1"),
      "tool/error-column": .tool("SELECT nope FROM docs"),
      "tool/error-trailing": .tool("SELECT 1; SELECT 2"),
      "web/query-count": .webQuery("SELECT count(*) FROM docs"),
      "web/query-forbidden": .webQuery("SELECT * FROM fs_heads"),
      "web/observe-docs": .webObserve("SELECT path, title FROM docs ORDER BY path"),
      "web/observe-viewer": .webObserve("SELECT viewer() AS v"),
    ]
    for table in [
      "docs", "links", "doc_custom_attrs", "sessions", "conversations", "conversation_members", "messages",
      "notifications", "watermarks", "devices", "device_commands", "/tasks.table",
    ] {
      probes["tool/all-\(table)"] = .tool("SELECT * FROM \"\(table)\" ORDER BY 1, 2")
    }
    return probes
  }

  // Each probe runs against its own copy of the fixture, so a mutation never
  // leaks into the next answer.
  static func answers(fixture: URL, meta: Goldens.Meta) async throws -> [String: String] {
    var answers: [String: String] = [:]
    for (name, probe) in probes(meta) {
      answers[name] = try await answer(probe, fixture: fixture, meta: meta)
    }
    return answers
  }

  /// Answers `probe` against a fresh copy of `fixture`, so no probe sees another's mutation.
  static func answer(_ probe: Probe, fixture: URL, meta: Goldens.Meta) async throws -> String {
    let scratch = try scratchURL("backcompat")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let file = scratch.appending(path: "space.sqlite")
    try Data(contentsOf: fixture).write(to: file)
    if try !Wuhu45Migration.isApplied(to: file) { try Wuhu45Migration.apply(to: file) }
    let web = switch probe {
    case .tool, .observe: false
    case .webQuery, .webObserve: true
    }
    let harness = try await Harness(dev: !web, opening: { try Space.open(file: file) })
    let answer = try await answer(probe, harness: harness, meta: meta)
    try await harness.space.close()
    return answer
  }

  private static func answer(_ probe: Probe, harness: Harness, meta: Goldens.Meta) async throws -> String {
    switch probe {
    case let .tool(sql):
      let response = try await harness.post("query", .object(["sql": .string(sql)]))
      return "\(response.status.code)\n" + (try await response.text())
    case let .observe(sql, mutation):
      let response = try await harness.get(harness.api, "/v1/observe", query: ["sql": sql, "throttleMs": "0"])
      return try await frames(response, count: mutation == nil ? 1 : 2) {
        if let mutation { try await mutate(mutation, harness: harness, meta: meta) }
      }
    case let .webQuery(sql):
      let response = try await harness.web(cookied("/_/query", sql: sql, meta: meta))
      return "\(response.status.code)\n" + (try await response.text())
    case let .webObserve(sql):
      let response = try await harness.web(cookied("/_/observe", sql: sql, meta: meta))
      return try await frames(response, count: 1) {}
    }
  }

  private static func frames(_ response: Response, count: Int, after first: () async throws -> Void) async throws -> String {
    guard response.status == .ok else { return "\(response.status.code)\n" + (try await response.text()) }
    var frames: [String] = []
    for try await event in response.sse() {
      frames.append(event.data)
      if frames.count == 1 { try await first() }
      if frames.count == count { break }
    }
    return (["200"] + frames).joined(separator: "\n")
  }

  private static func cookied(_ path: String, sql: String, meta: Goldens.Meta) -> Request {
    var components = URLComponents(string: "http://space")!
    components.path = path
    components.queryItems = [URLQueryItem(name: "sql", value: sql)]
    var headers = RequestHeaders()
    headers[.cookie] = "wuhu_read=" + meta.cookie
    return Request(url: components.url!, headers: headers)
  }

  private static func mutate(_ mutation: Mutation, harness: Harness, meta: Goldens.Meta) async throws {
    switch mutation {
    case .readTheBox:
      try await harness.space.sessions.advanceWatermark(identity: harness.space.ensureDevPerson().persona, source: meta.box)
    case .insertATask:
      _ = try await harness.direct("table.mutate", .object([
        "path": "/tasks.table",
        "ops": .array([.object(["kind": "insert", "values": .array(["Late", false, .null, 0, .null])])]),
      ]))
    case .writeADoc:
      _ = try await harness.direct("write", .object([
        "path": "/notes/c.md", "content": "---\nsort: 0\ntitle: First\n---\n# C\n",
      ]))
    }
  }

  static func buildFixture(at destination: URL) async throws -> Goldens.Meta {
    let scratch = try scratchURL("backcompat-build")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let file = scratch.appending(path: "space.sqlite")
    let deviceKey = Curve25519.Signing.PrivateKey()

    let meta = try await fixtureDependencies(fixedDate) { at in
      let space = try Space.open(file: file)
      registerSessionCells(in: space)
      let person = try await space.ensureDevPerson()
      let fs = await space.fs(.shared)
      for (path, content) in [
        ("/models.json", testModelsJSON),
        ("/index.md", "# Home\n\nSee [a](/notes/a.md) and [b](/notes/b.md).\n"),
        ("/notes/a.md", "---\nkind: note\nstatus: open\nsort: 2\ntags: [x, y]\ntitle: Alpha\n---\n# A\n"),
        ("/notes/b.md", "---\nparent: /notes/a.md\nsort: 1\n---\n# B\n\nBack to [a](a.md).\n"),
        ("/data.json", "{\"n\":1}"),
      ] {
        _ = try await fs.write(path, Data(content.utf8), ifMatch: nil)
      }
      let context = SpaceToolContext(space: space, principal: .shared(person.actor))
      func tool(_ name: String, _ input: JSONValue) async throws {
        _ = try await SpaceToolbox.all.first { $0.name == name }!.run(context, input: input)
      }
      try await tool("table.create", .object([
        "path": "/tasks.table",
        "header": .object(["columns": .array([
          .object(["name": "title", "type": "string"]),
          .object(["name": "done", "type": "boolean"]),
          .object(["name": "meta", "type": "json"]),
          .object(["name": "points", "type": "integer"]),
          .object(["name": "weight", "type": "number"]),
        ])]),
      ]))
      try await tool("table.mutate", .object([
        "path": "/tasks.table",
        "ops": .array([
          .object(["kind": "insert", "values": .array(["Ship", true, .object(["a": .array([1, 2])]), 3, 1.5])]),
          .object(["kind": "insert", "values": .array(["Wait", false, .null, .null, .null])]),
          .object(["kind": "insert", "values": .array(["Quote's", .null, "text", -1, 0])]),
        ]),
      ]))

      let store = space.sessions
      let model = ModelSpecifier(provider: "testing", model: "test-model", effort: "high")
      let utc = TimeZone(identifier: "UTC")!
      at(fixedDate.addingTimeInterval(7))
      let lead = try await store.createSession(group: .shared, title: "Lead", kind: .agent, tags: ["crew"], createdBy: person.persona, model: model)
      at(fixedDate.addingTimeInterval(8))
      _ = try await store.createSession(
        group: .shared,
        title: "Helper", kind: .task, parent: lead, createdBy: person.persona, executor: .kernel(model),
      )
      at(fixedDate.addingTimeInterval(9))
      let quiet = try await store.createSession(group: .shared, title: "Quiet", kind: .agent, createdBy: person.persona, model: model)
      for (box, ask, answer, offset) in [(lead, "m1", "m2", 10), (quiet, "m3", "m4", 12)] {
        at(fixedDate.addingTimeInterval(Double(offset)))
        _ = try await store.post(
          .box(box), messageID: MessageID(ask), sender: Sender(id: person.persona, timeZone: utc), content: .init(text: "q"),
        )
        try await store.deliverMail(box)
        at(fixedDate.addingTimeInterval(Double(offset + 1)))
        _ = try await store.post(
          .box(box), messageID: MessageID(answer), sender: Sender(id: box.rawValue, timeZone: utc),
          senderSession: box, replyTarget: MessageID(ask), content: .init(text: "a"),
        )
        try await store.deliverMail(box)
      }
      try await store.advanceWatermark(identity: person.persona, source: quiet.rawValue)

      let owner = try #require(try await space.account(person.account))
      _ = try await space.addKey(
        deviceKey.pubkeyLabel, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil,
      )
      at(fixedDate.addingTimeInterval(17))
      let device = try await space.upsertDevice(
        pubkey: deviceKey.pubkeyLabel, installation: "install-1", kind: "mac", name: "Studio",
      )
      at(fixedDate.addingTimeInterval(18))
      _ = try await space.issueDeviceCommand(device: device.id, payload: "{\"sidebar\":\"everything\"}", issuedBy: person.persona)
      let cookie = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: Date(timeIntervalSince1970: 4_102_444_800))
      try await space.close()
      return Goldens.Meta(box: lead.rawValue, device: device.id, cookie: cookie.rawValue)
    }

    // A command the app's 60-second window keeps whenever the replay runs.
    try await fixtureDependencies(Date(timeIntervalSince1970: 4_102_444_800)) { _ in
      let space = try Space.open(file: file)
      let person = try await space.ensureDevPerson()
      _ = try await space.issueDeviceCommand(device: meta.device, payload: "{\"sidebar\":\"/.sidebars/a.json\"}", issuedBy: person.persona)
      try await space.close()
    }

    try RawDatabase.open(file.path) { try $0.execute(sql: "VACUUM INTO ?", arguments: [destination.path]) }
    return meta
  }

  private static func fixtureDependencies<R>(_ date: Date, _ body: (@Sendable (Date) -> Void) async throws -> R) async throws -> R {
    let clock = Mutex(date)
    return try await withDependencies {
      $0.date = DateGenerator { clock.withLock { $0 } }
      $0.uuid = .incrementing
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 45))
    } operation: {
      try await body { stamp in clock.withLock { $0 = stamp } }
    }
  }
}
