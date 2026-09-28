import JSONValue
import SpaceContract
import Testing

@Suite
struct SpaceContractCodingTests {
  private let encoder = JSONValueEncoder()
  private let decoder = JSONValueDecoder()

  @Test func mutationEventEncodesInternallyTagged() throws {
    #expect(try encoder.encode(MutationEvent.write(path: "notes/a.md", rev: 7, entry: .file)) == .object([
      "kind": "write", "path": "notes/a.md", "rev": 7, "entry": "file",
    ]))
    #expect(try encoder.encode(MutationEvent.move(path: "a", to: "b", rev: 9, entry: .directory)) == .object([
      "kind": "move", "path": "a", "to": "b", "rev": 9, "entry": "directory",
    ]))
  }

  @Test func rowOpCarriesTypedJSONCellValues() throws {
    #expect(try encoder.encode(RowOp.insert(values: [.string("Buy milk"), .integer(5), .null])) == .object([
      "kind": "insert", "values": .array([.string("Buy milk"), .integer(5), .null]),
    ]))
    #expect(try encoder.encode(RowOp.update(row: 3, values: [.bool(true)])) == .object([
      "kind": "update", "row": 3, "values": .array([.bool(true)]),
    ]))
    #expect(try encoder.encode(RowOp.delete(row: 2)) == .object(["kind": "delete", "row": 2]))
  }

  @Test func observeInputOmitsAbsentOptionals() throws {
    #expect(try encoder.encode(ObserveInput.glob(pattern: "notes/**", from: nil)) == .object([
      "kind": "glob", "pattern": "notes/**",
    ]))
    #expect(try encoder.encode(ObserveInput.glob(pattern: "notes/**", from: 42)) == .object([
      "kind": "glob", "pattern": "notes/**", "from": 42,
    ]))
    #expect(try encoder.encode(ObserveInput.sql(query: "select 1", throttleMs: nil)) == .object([
      "kind": "sql", "query": "select 1",
    ]))
  }

  @Test func queryOutputCarriesTypedJSONCells() throws {
    let json: JSONValue = .object([
      "columns": .array([.string("name"), .string("done")]),
      "rows": .array([
        .array([.string("Buy milk"), .bool(false)]),
        .array([.string("Ship"), .integer(1)]),
      ]),
    ])
    #expect(try encoder.encode(decoder.decode(QueryOutput.self, from: json)) == json)
  }

  @Test func absentOptionalDecodesNilAndReEncodesAbsent() throws {
    let json: JSONValue = .object([
      "name": "notes", "kind": "directory", "size": 0, "token": "t2", "mtime": 2,
    ])
    let entry = try decoder.decode(Entry.self, from: json)
    #expect(entry.lineCount == nil)
    #expect(try encoder.encode(entry) == json)

    let error = try decoder.decode(ToolError.self, from: .object(["code": "conflict", "message": "stale"]))
    #expect(error.hint == nil)
    #expect(try encoder.encode(error) == .object(["code": "conflict", "message": "stale"]))
  }

  @Test func dataViewTagsOnView() throws {
    let doc = DataView.kanban(
      title: "Work board",
      sql: "SELECT * FROM \"/tasks.table\"",
      config: KanbanConfig(groupBy: "status", cardTitle: "title", sort: "priority", path: nil),
    )
    #expect(try encoder.encode(doc) == .object([
      "view": "kanban",
      "title": "Work board",
      "sql": "SELECT * FROM \"/tasks.table\"",
      "config": .object(["groupBy": "status", "cardTitle": "title", "sort": "priority"]),
    ]))
    #expect(try decoder.decode(DataView.self, from: encoder.encode(doc)) == doc)
  }

  @Test func dataViewDecodeRejectsUnknownView() {
    #expect(throws: (any Error).self) {
      try decoder.decode(DataView.self, from: .object(["view": "gantt", "sql": "SELECT 1"]))
    }
  }

  @Test func listWallAndMapTagOnView() throws {
    let views: [DataView] = [
      .list(
        title: "Observation list",
        sql: "SELECT 1",
        config: ListConfig(path: "path", cardTitle: "title", subtitle: "subtitle"),
      ),
      .wall(title: nil, sql: "SELECT 1", config: WallConfig(path: "path", title: "title")),
      .map(
        title: "Map",
        sql: "SELECT 1",
        config: MapConfig(nodeID: "path", nodeTitle: "title", parentID: "parent", root: "/a.md"),
      ),
    ]
    for view in views {
      #expect(try decoder.decode(DataView.self, from: encoder.encode(view)) == view)
    }
    #expect(try encoder.encode(views[1]) == .object([
      "view": "wall",
      "sql": "SELECT 1",
      "config": .object(["path": "path", "title": "title"]),
    ]))
  }

  @Test func viewDocumentsInTheWildDecode() throws {
    let decoded = try liveViewDocuments.map { document in
      try decoder.decode(DataView.self, from: try #require(JSONValue.parse(document)))
    }
    guard case let .list(library, _, list) = decoded[0],
          case let .list(_, _, checks) = decoded[1],
          case let .wall(_, _, wall) = decoded[2],
          case let .map(_, sql, map) = decoded[3]
    else {
      #expect(Bool(false), "a live view document decoded as the wrong kind")
      return
    }
    #expect(library == "Observation list")
    #expect(list == ListConfig(path: "path", cardTitle: "title", subtitle: "subtitle"))
    #expect(checks.subtitle == "subtitle")
    #expect(wall == WallConfig(path: "path", title: "title"))
    #expect(map == MapConfig(nodeID: "path", nodeTitle: "title", parentID: "parent", root: "/demo/visionos/index.md"))
    #expect(sql.hasPrefix("SELECT d.path AS path"))
  }
}

private let liveViewDocuments = [
  #"""
  {
    "title": "Observation list",
    "sql": "SELECT d.path AS path, COALESCE(json_extract(t.value,'$'), d.title) AS title, json_extract(h.value,'$') AS subtitle FROM docs d LEFT JOIN doc_custom_attrs t ON t.path = d.path AND t.name = 'title' LEFT JOIN doc_custom_attrs h ON h.path = d.path AND h.name = 'headline' WHERE d.path LIKE '/demo/visionos/observations/2026-%' ORDER BY d.path",
    "view": "list",
    "config": {
      "path": "path",
      "cardTitle": "title",
      "subtitle": "subtitle"
    }
  }
  """#,
  #"""
  {
    "title": "Route checks",
    "sql": "SELECT '/demo/sunday/route-notes.md' AS path, \"check\" AS title, evidence AS subtitle FROM \"/demo/sunday/route-checks.table\" ORDER BY id",
    "view": "list",
    "config": { "path": "path", "cardTitle": "title", "subtitle": "subtitle" }
  }
  """#,
  #"""
  {
    "title": "Document wall",
    "sql": "SELECT d.path AS path, COALESCE(json_extract(t.value,'$'), d.title) AS title FROM docs d LEFT JOIN doc_custom_attrs t ON t.path = d.path AND t.name = 'title' WHERE d.path LIKE '/demo/visionos/observations/2026-%' ORDER BY d.path",
    "view": "wall",
    "config": {
      "path": "path",
      "title": "title"
    }
  }
  """#,
  #"""
  {
    "title": "Map",
    "sql": "SELECT d.path AS path, COALESCE(json_extract(mt.value,'$'), json_extract(t.value,'$'), d.title) AS title, json_extract(p.value,'$') AS parent FROM docs d LEFT JOIN doc_custom_attrs mt ON mt.path = d.path AND mt.name = 'map_title' LEFT JOIN doc_custom_attrs t ON t.path = d.path AND t.name = 'title' LEFT JOIN doc_custom_attrs p ON p.path = d.path AND p.name = 'parent' LEFT JOIN doc_custom_attrs s ON s.path = d.path AND s.name = 'sort' WHERE d.path LIKE '/demo/visionos/%' AND d.path NOT LIKE '/demo/visionos/_verification/%' AND (d.path = '/demo/visionos/index.md' OR p.value IS NOT NULL) ORDER BY COALESCE(json_extract(s.value,'$'), 9999)",
    "view": "map",
    "config": {
      "nodeID": "path",
      "nodeTitle": "title",
      "parentID": "parent",
      "root": "/demo/visionos/index.md"
    }
  }
  """#,
]

@Suite
struct SessionLogCodingTests {
  private let encoder = JSONValueEncoder()
  private let decoder = JSONValueDecoder()

  @Test func logOutputOmitsAbsentOptionals() throws {
    let kernel = SessionLogOutput(
      context: SessionContext(usedTokens: 10, maxTokens: 100, percentage: 10, updatedAt: nil, source: .estimate),
      items: [SessionLogItem(ref: "2:41", receivedAt: nil, emittedAt: nil, item: .object(["direct": .object([:])]))],
    )
    #expect(try encoder.encode(kernel) == .object([
      "context": .object(["usedTokens": 10, "maxTokens": 100, "percentage": 10, "source": "estimate"]),
      "items": .array([.object(["ref": "2:41", "item": .object(["direct": .object([:])])])]),
    ]))
  }

  private func message(attachments: JSONValue?) -> JSONValue {
    guard let attachments else {
      return [
        "n": 7, "messageId": "msg_7", "conversationId": "c", "kind": "message", "sender": "owner",
        "senderTimezone": "UTC", "text": "look", "createdAt": 1_756_800_000,
      ]
    }
    return [
      "n": 7, "messageId": "msg_7", "conversationId": "c", "kind": "message", "sender": "owner",
      "senderTimezone": "UTC", "text": "look", "attachments": attachments, "createdAt": 1_756_800_000,
    ]
  }

  @Test func anAttachmentFromAServerBeforeFilesIsTheBarePathOfAnImage() throws {
    let decoded = try decoder.decode(ConversationMessagePayload.self, from: message(attachments: ["/_/c/a.png", "/_/c/b.jpg"]))
    #expect(decoded.attachments == [
      AttachmentPayload(kind: .image, path: "/_/c/a.png", mimeType: "image/png", size: nil),
      AttachmentPayload(kind: .image, path: "/_/c/b.jpg", mimeType: "image/jpeg", size: nil),
    ])
  }

  @Test func anAttachmentObjectDecodesAndIgnoresKeysItDoesNotKnow() throws {
    let decoded = try decoder.decode(ConversationMessagePayload.self, from: message(attachments: [
      ["kind": "file", "path": "/_/c/clip.mp4", "mimeType": "video/mp4", "size": 42, "thumbnail": "/_/c/clip.jpg"],
      ["kind": "image", "path": "/_/c/a.png", "mimeType": "image/png"],
    ]))
    #expect(decoded.attachments == [
      AttachmentPayload(kind: .file, path: "/_/c/clip.mp4", mimeType: "video/mp4", size: 42),
      AttachmentPayload(kind: .image, path: "/_/c/a.png", mimeType: "image/png", size: nil),
    ])
    #expect(try encoder.encode(decoded.attachments![0]) == .object([
      "kind": "file", "path": "/_/c/clip.mp4", "mimeType": "video/mp4", "size": 42,
    ]))
  }

  @Test func aMessageWithoutAttachmentsDecodesWithNone() throws {
    #expect(try decoder.decode(ConversationMessagePayload.self, from: message(attachments: nil)).attachments == nil)
  }
}
