import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

// Sessions, settings and conversations by group on the API: alice is the
// person's personal group, bob another person's.
@Suite struct GroupRoutesTests {
  struct People {
    let harness: SessionHarness
    let bearer: String
    let key: KeyRecord
    let alice: GroupID
    let bob: GroupID
  }

  func people() async throws -> People {
    let harness = try await SessionHarness(dev: false, origin: "https://space.test:5530")
    let (bearer, key) = try await harness.enrolledBearer()
    let alice = try await harness.space.ensurePersonalGroup(account: key.account)
    let bob = try await harness.space.ensurePersonalGroup(account: try await harness.space.addAccount(kind: .human, name: nil).id)
    return People(harness: harness, bearer: bearer, key: key, alice: alice, bob: bob)
  }

  func send(
    _ people: People, _ method: Fetch.Method, _ path: String, _ body: JSONValue? = nil, group: GroupID? = nil,
    bearer: String? = nil,
  ) async throws -> Response {
    var request = Request(url: URL(string: "https://space.test\(path)")!, method: method)
    if let body { request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json") }
    request.headers[.authorization] = "Bearer " + (bearer ?? people.bearer)
    if let group { request.headers[GroupHeader.name] = group.rawValue }
    return try await people.harness.api(request)
  }

  func code(_ response: Response) async throws -> String? {
    try await json(response).object?["code"]?.stringValue
  }

  @Test func anAdminTurnsTheSpaceWideLayerOffForTheirGroupOnly() async throws {
    try await withSessionDeps {
      let p = try await people()
      let off = try await send(p, .put, "/v1/groups/\(p.alice.rawValue)", .object(["spaceLayer": false]))
      #expect(off.status == .ok)
      #expect(try await json(off) == .object(["id": .string(p.alice.rawValue), "spaceLayer": false]))
      #expect(try await !p.harness.space.spaceLayer(of: p.alice))
      let foreign = try await send(p, .put, "/v1/groups/\(p.bob.rawValue)", .object(["spaceLayer": false]))
      #expect(foreign.status == .forbidden)
      #expect(try await code(foreign) == "forbidden")
      #expect(try await p.harness.space.spaceLayer(of: p.bob))
      let unknown = try await send(p, .put, "/v1/groups/nowhere", .object(["spaceLayer": false]))
      #expect(unknown.status == .notFound)
      #expect(try await code(unknown) == "unknownGroup")
    }
  }

  @Test func aTopLevelSessionLandsInTheActingGroupOrAReadableOne() async throws {
    try await withSessionDeps {
      let p = try await people()
      func create(_ group: String?) async throws -> Response {
        let body: JSONValue = .object([
          "title": "t", "kind": "agent", "provider": "testing", "model": "test-model",
          "group": group.map(JSONValue.string) ?? .null,
        ])
        return try await send(p, .post, "/v1/session", body, group: p.alice)
      }
      let own = try await create(nil)
      #expect(own.status == .ok)
      let ownID = try #require(try await json(own).object?["id"]?.stringValue)
      #expect(try await p.harness.store.record(SessionID(ownID)).group == p.alice)
      let shared = try await create("shared")
      #expect(shared.status == .ok)
      let sharedID = try #require(try await json(shared).object?["id"]?.stringValue)
      #expect(try await p.harness.store.record(SessionID(sharedID)).group == .shared)
      let foreign = try await create(p.bob.rawValue)
      #expect(foreign.status == .forbidden)
      #expect(try await code(foreign) == "groupForbidden")
    }
  }

  @Test func aBoxInAnUnreadGroupReadsAsMissing() async throws {
    try await withSessionDeps {
      let p = try await people()
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let theirs = try await p.harness.store.createSession(group: p.bob, title: "b", kind: .agent, createdBy: "owner", executor: model)
      let ours = try await p.harness.store.createSession(group: p.alice, title: "a", kind: .agent, createdBy: "owner", executor: model)
      let refused = try await send(p, .get, "/v1/conversation/\(theirs.rawValue)/messages", group: p.alice)
      #expect(refused.status == .notFound)
      #expect(try await code(refused) == "notFound")
      #expect(try await send(p, .get, "/v1/conversation/\(ours.rawValue)/messages", group: p.alice).status == .ok)
    }
  }

  func session(_ p: People, in group: GroupID, _ title: String = "s") async throws -> SessionID {
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    return try await p.harness.store.createSession(group: group, title: title, kind: .agent, createdBy: "owner", executor: model)
  }

  @Test func everySurfaceThatReturnsAMessageCarriesTheSenderGroup() async throws {
    try await withSessionDeps {
      let p = try await people()
      let s = try await session(p, in: .shared)
      let ours = try await session(p, in: p.alice)
      _ = try await p.harness.store.post(
        .box(s), messageID: MessageID("m1"), sender: Sender(id: ours.rawValue, timeZone: .gmt), senderSession: ours,
        content: .init(text: "from alice"),
      )
      let read = try await send(p, .get, "/v1/conversation/\(s.rawValue)/messages")
      #expect(read.status == .ok)
      let messages = try JSONValueDecoder().decode(ConversationReadOutput.self, from: try await json(read)).messages
      #expect(messages.map(\.senderGroup) == [p.alice.rawValue])

      let observed = try await send(p, .get, "/v1/conversation/\(s.rawValue)/observe")
      #expect(observed.status == .ok)
      for try await frame in observed.sse() {
        let entry = try JSONValueDecoder().decode(ConversationMessagePayload.self, from: #require(JSONValue.parse(frame.data)))
        #expect(entry.senderGroup == p.alice.rawValue)
        break
      }

      let senders = try await send(p, .post, "/v1/tools/query", .object(["sql": "SELECT sender_grp FROM message_senders"]))
      #expect(try await json(senders).object?["rows"] == .array([.array([.string(p.alice.rawValue)])]))
    }
  }

  @Test func aSessionInAnUnreadGroupIsUnknownToEveryRouteBeforeAnyEffect() async throws {
    try await withSessionDeps {
      let p = try await people()
      let theirs = try await session(p, in: p.bob)
      let id = theirs.rawValue
      let before = try await p.harness.store.promptRevision(theirs)
      _ = try await p.harness.space.fs(.shared).write("/bump.md", Data("x".utf8), ifMatch: nil)

      for path in ["transcript", "direct", "context", "home", "log", "entry/1"] {
        let response = try await send(p, .get, "/v1/session/\(id)/\(path)", group: p.alice)
        #expect(response.status == .notFound, "\(path)")
        #expect(try await code(response) == "notFound", "\(path)")
      }
      let steering: [(String, JSONValue?)] = [
        ("compact", .object(["instructions": "forget everything"])),
        ("restart", .object(["message": "wake up"])),
        ("tags", .object(["tags": .array(["x"])])),
        ("title", .object(["title": "mine"])),
        ("interrupt", nil),
        ("resume", nil),
        ("archive", nil),
      ]
      for (verb, body) in steering {
        let response = try await send(p, .post, "/v1/session/\(id)/\(verb)", body, group: p.alice)
        #expect(response.status == .notFound, "\(verb)")
        #expect(try await code(response) == "notFound", "\(verb)")
      }
      let record = try await p.harness.store.record(theirs)
      #expect(record.title == "s")
      #expect(record.tags.isEmpty)
      #expect(try await p.harness.store.promptRevision(theirs) == before)
      #expect(try await p.harness.store.messages(conversation: ConversationID(id)).isEmpty)
    }
  }

  @Test func aConversationObservedFromAnUnreadGroupReadsAsMissing() async throws {
    try await withSessionDeps {
      let p = try await people()
      let theirs = try await session(p, in: p.bob)
      let refused = try await send(p, .get, "/v1/conversation/\(theirs.rawValue)/observe", group: p.alice)
      #expect(refused.status == .notFound)
      #expect(try await code(refused) == "notFound")
    }
  }

  @Test func templatesAreTheActingGroups() async throws {
    try await withSessionDeps {
      let p = try await people()
      let manifest = Data(#"{"kind":"agent","description":"d"}"#.utf8)
      _ = try await p.harness.space.fs(.shared).write("/templates/everyone/template.json", manifest, ifMatch: nil)
      _ = try await p.harness.space.fs(p.alice).write("/templates/mine/template.json", manifest, ifMatch: nil)
      func names(_ group: GroupID) async throws -> [String] {
        let response = try await send(p, .get, "/v1/templates", group: group)
        return try JSONValueDecoder().decode(SessionTemplatesOutput.self, from: try await json(response)).templates.map(\.name)
      }
      #expect(try await names(p.alice) == ["mine"])
      #expect(try await names(.shared) == ["everyone"])
    }
  }

  @Test func aPersonSpeaksAsTheVerifiedPersonaTheyName() async throws {
    try await withSessionDeps {
      let p = try await people()
      let first = try await p.harness.space.adoptPersona(key: p.key)
      let second = try await p.harness.space.mintPersona(key: p.key)
      for persona in [first.name, second.name] {
        try await p.harness.store.advanceWatermark(identity: persona, source: "somewhere")
      }
      let sql: JSONValue = .object(["sql": "SELECT identity FROM watermarks"])
      let asFirst = try await send(p, .post, "/v1/tools/query", sql)
      #expect(try await json(asFirst).object?["rows"] == .array([.array([.string(first.name)])]))
      let asSecond = try await send(p, .post, "/v1/tools/query?identity=\(second.name)", sql)
      #expect(try await json(asSecond).object?["rows"] == .array([.array([.string(second.name)])]))

      let (_, otherKey) = try await p.harness.enrolledBearer()
      let foreign = try await p.harness.space.adoptPersona(key: otherKey)
      let notYours = try await send(p, .post, "/v1/tools/query?identity=\(foreign.name)", sql)
      #expect(notYours.status == .forbidden)
      #expect(try await code(notYours) == "identityNotYours")
      let (contractor, _) = try await p.harness.enrolledBearer(account: p.key.account, capabilities: [.contractor])
      let keyless = try await send(p, .post, "/v1/tools/query?identity=\(second.name)", sql, bearer: contractor)
      #expect(keyless.status == .forbidden)
      #expect(try await code(keyless) == "personaRequiresDevice")

      let dm = try await p.harness.store.post(
        .dm(with: second.name), messageID: MessageID("m1"), sender: Sender(id: foreign.name, timeZone: .gmt),
        content: .init(text: "hi"), acting: Principal(actor: .anonymous, group: p.bob),
      )
      func listed(_ query: String) async throws -> [String] {
        let response = try await send(p, .get, "/v1/conversations\(query)", group: p.alice)
        return try JSONValueDecoder().decode(ConversationsOutput.self, from: try await json(response)).conversations.map(\.id)
      }
      #expect(try await listed("") == [])
      // Homed in bob, which alice does not read: listed and notified because
      // the persona is a member.
      #expect(try await listed("?identity=\(second.name)") == [dm.message.conversation.rawValue])
      let notified = try await send(
        p, .post, "/v1/tools/query?identity=\(second.name)", .object(["sql": "SELECT source FROM notifications"]), group: p.alice,
      )
      #expect(try await json(notified).object?["rows"] == .array([.array([.string(dm.message.conversation.rawValue)])]))
    }
  }
}
