import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import Testing

// A page's createSession and sendMessage act as its viewer, never a guest,
// with the viewer's authority intersected with the page's group at every step.
@Suite(.deterministicDependencies) struct PageSessionRouteTests {
  struct Rig {
    let harness: SessionHarness
    let alice: AccountID
    let persona: String
    let aliceGroup: GroupID

    var sharedHost: String { "shared.space.test:5530" }
    var aliceHost: String { "\(aliceGroup.rawValue).space.test:5530" }
  }

  func rig() async throws -> Rig {
    let harness = try await SessionHarness(dev: false, origin: "https://space.test:5530")
    let alice = try await harness.space.addAccount(kind: .human, name: "alice", admin: true).id
    return Rig(
      harness: harness, alice: alice, persona: try await harness.space.persona(account: alice)?.name ?? alice.rawValue,
      aliceGroup: try await harness.space.ensurePersonalGroup(account: alice),
    )
  }

  func cookie(_ rig: Rig, _ account: AccountID, _ group: GroupID) async throws -> String {
    @Dependency(\.date) var date
    return "wuhu_read=" + (try await rig.harness.space.createReadSession(
      account: account, group: group, expiresAt: date.now.addingTimeInterval(3600),
    )).rawValue
  }

  func post(_ rig: Rig, _ host: String, _ route: String, _ body: JSONValue, cookie: String) async throws -> Response {
    var request = Request(url: URL(string: "https://\(host)/_/space/\(route)")!, method: .post)
    request.headers[.origin] = "https://\(host)"
    request.headers[HTTPField.Name("Sec-Fetch-Site")!] = "same-origin"
    request.headers[.contentType] = "application/json"
    request.headers[.cookie] = cookie
    var fields = body.object ?? [:]
    fields["page"] = "/apps/board.html"
    request.body = .string(JSONValue.object(fields).jsonString())
    return try await rig.harness.api(request)
  }

  func code(_ response: Response) async throws -> String? {
    JSONValue.parse(try await response.text())?.object?["code"]?.stringValue
  }

  @Test func aPageCreatesAnAgentAndPostsAsItsViewer() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let alices = try await cookie(r, r.alice, .shared)
      let options: JSONValue = ["title": "helper", "provider": "testing", "model": "test-model", "message": "start", "key": "helper"]
      let created = try await post(r, r.sharedHost, "session", options, cookie: alices)
      #expect(created.status == .ok)
      let output = try JSONValueDecoder().decode(SessionCreateOutput.self, from: try #require(JSONValue.parse(try await created.text())))
      #expect(output.kind == .agent)
      #expect(output.parent == nil)
      let replayed = try await post(r, r.sharedHost, "session", options, cookie: alices)
      #expect(try JSONValueDecoder().decode(SessionCreateOutput.self, from: try #require(JSONValue.parse(try await replayed.text()))).id == output.id)

      let id = SessionID(output.id)
      let record = try await r.harness.store.record(id)
      #expect(record.group == .shared)
      #expect(record.createdBy == r.persona)

      let sent = try await post(r, r.sharedHost, "message", ["session": .string(output.id), "message": "more"], cookie: alices)
      #expect(sent.status == .ok)
      let messages = try await r.harness.store.messages(conversation: ConversationID(output.id))
      #expect(messages.map(\.content.text) == ["start", "more"])
      #expect(messages.allSatisfy { $0.sender.id == r.persona && $0.senderSession == nil })
    }
  }

  @Test func aPagesRequestOpensInTheAgentsBoxAndItsFinalAnswersThere() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let alices = try await cookie(r, r.alice, .shared)
      let options: JSONValue = [
        "title": "helper", "provider": "testing", "model": "test-model", "message": "triage #7", "expectsReply": true,
        "request": ["kind": "triage", "key": "issue-7", "fields": ["issue": 7]], "key": "call-1",
      ]
      let created = try await post(r, r.sharedHost, "session", options, cookie: alices)
      #expect(created.status == .ok)
      let output = try JSONValueDecoder().decode(SessionCreateOutput.self, from: try #require(JSONValue.parse(try await created.text())))
      let request = try #require(output.requestId)
      let id = SessionID(output.id)
      #expect(output.parent == nil)

      let row = try await r.harness.space.query("SELECT requester, task, kind, key, status FROM requests", as: .shared(.anonymous)).rows
      #expect(row == [[.text(r.persona), .text(output.id), .text("triage"), .text("issue-7"), .text("open")]])

      var retry = options.object!
      retry["key"] = "call-2"
      let again = try JSONValueDecoder().decode(
        SessionCreateOutput.self, from: try #require(JSONValue.parse(try await post(r, r.sharedHost, "session", .object(retry), cookie: alices).text())),
      )
      #expect(again.id == output.id)
      #expect(again.requestId == request)
      #expect(again.existing == true)

      _ = try await r.harness.store.drainQueue(id)
      _ = try await r.harness.store.report(id, request: RequestID(request), kind: .final, messageID: MessageID("f1"), text: "fixed")
      let messages = try await r.harness.store.messages(conversation: ConversationID(output.id))
      #expect(messages.map(\.kind) == [.request, .final])
      #expect(messages.map(\.content.text) == ["triage #7", "fixed"])
      #expect(messages.first?.sender.id == r.persona)
      #expect(messages.last?.senderSession == id)
      let status = try await r.harness.space.query("SELECT status, result FROM requests", as: .shared(.anonymous)).rows
      #expect(status == [[.text("done"), .text(#""fixed""#)]])
    }
  }

  @Test func aGuestsPageCreatesAndPostsNothing() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let guest = try await r.harness.space.addAccount(kind: .human, name: "guest", guest: true).id
      try await r.harness.space.setGrant(
        .account, guest.rawValue, role: .read, in: .shared,
        by: .person(persona: r.persona, account: r.alice), acting: .shared,
      )
      let guests = try await cookie(r, guest, .shared)
      let agent = try await r.harness.store.createSession(
        group: .shared, title: "agent", kind: .agent, createdBy: r.persona,
        executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
      )
      for (route, body) in [
        ("session", ["title": "helper", "provider": "testing", "model": "test-model"] as JSONValue),
        ("message", ["session": .string(agent.rawValue), "message": "hi"]),
      ] {
        let refused = try await post(r, r.sharedHost, route, body, cookie: guests)
        #expect(refused.status == .forbidden, "\(route)")
        #expect(try await code(refused) == "groupForbidden", "\(route)")
      }
      #expect(try await r.harness.store.messages(conversation: ConversationID(agent.rawValue)).isEmpty)
    }
  }

  @Test func aPageActsOnlyInItsOwnGroup() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let alices = try await cookie(r, r.alice, r.aliceGroup)
      let elsewhere = try await post(
        r, r.aliceHost, "session", ["title": "helper", "provider": "testing", "model": "test-model", "group": "shared"], cookie: alices,
      )
      #expect(elsewhere.status == .forbidden)
      #expect(try await code(elsewhere) == "outsidePageGroup")

      let shared = try await r.harness.store.createSession(
        group: .shared, title: "agent", kind: .agent, createdBy: r.persona,
        executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
      )
      let crossing = try await post(r, r.aliceHost, "message", ["session": .string(shared.rawValue), "message": "hi"], cookie: alices)
      #expect(crossing.status == .forbidden)
      #expect(try await code(crossing) == "outsidePageGroup")
      #expect(try await r.harness.store.messages(conversation: ConversationID(shared.rawValue)).isEmpty)

      let own = try await post(r, r.aliceHost, "session", ["title": "mine", "provider": "testing", "model": "test-model"], cookie: alices)
      #expect(own.status == .ok)
    }
  }

  func agent(_ r: Rig, in group: GroupID) async throws -> SessionID {
    try await r.harness.store.createSession(
      group: group, title: "agent", kind: .agent, createdBy: r.persona,
      executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
    )
  }

  func created(_ response: Response) async throws -> SessionID {
    SessionID(try JSONValueDecoder().decode(SessionCreateOutput.self, from: try #require(JSONValue.parse(try await response.text()))).id)
  }

  @Test func aKeyTheViewerUsedInAnotherGroupNeverReplaysThere() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let options: JSONValue = ["title": "helper", "provider": "testing", "model": "test-model", "key": "k"]
      var privately = options.object!
      privately["message"] = "private"
      let mine = try await created(post(r, r.aliceHost, "session", .object(privately), cookie: cookie(r, r.alice, r.aliceGroup)))
      var publicly = options.object!
      publicly["message"] = "public"
      let theirs = try await created(post(r, r.sharedHost, "session", .object(publicly), cookie: cookie(r, r.alice, .shared)))
      #expect(theirs != mine)
      #expect(try await r.harness.store.record(theirs).group == .shared)
      #expect(try await r.harness.store.messages(conversation: ConversationID(mine.rawValue)).map(\.content.text) == ["private"])
      #expect(try await r.harness.store.messages(conversation: ConversationID(theirs.rawValue)).map(\.content.text) == ["public"])
    }
  }

  @Test func aPageAttachesOnlyItsOwnGroupsFiles() async throws {
    try await withSessionDeps {
      let r = try await rig()
      _ = try await r.harness.space.fs(r.aliceGroup).write("/secret.md", Data("secret".utf8), ifMatch: nil)
      _ = try await r.harness.space.fs(.shared).write("/notes.md", Data("notes".utf8), ifMatch: nil)
      let shared = try await agent(r, in: .shared)
      let alices = try await cookie(r, r.alice, .shared)
      for reference in ["wuhu://\(r.aliceGroup.rawValue).localspace/secret.md", "wuhu://system/AGENTS.md"] {
        let refused = try await post(
          r, r.sharedHost, "message", ["session": .string(shared.rawValue), "message": "look", "attachments": [.string(reference)]], cookie: alices,
        )
        #expect(refused.status == .forbidden, "\(reference)")
        #expect(try await code(refused) == "outsidePageGroup", "\(reference)")
      }
      #expect(try await r.harness.store.messages(conversation: ConversationID(shared.rawValue)).isEmpty)
      let own = try await post(
        r, r.sharedHost, "message", ["session": .string(shared.rawValue), "message": "look", "attachments": ["/notes.md"]], cookie: alices,
      )
      #expect(own.status == .ok)
    }
  }

  @Test func aViewerWhoOnlyReadsThePagesGroupCreatesAndPostsNothing() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let alice = Actor.person(persona: r.persona, account: r.alice)
      let team = try await r.harness.space.createGroup(alias: "team", owner: r.alice)
      try await r.harness.space.setVisibility(.private, of: team, by: alice, acting: team)
      let bob = try await r.harness.space.addAccount(kind: .human, name: "bob").id
      try await r.harness.space.setGrant(.account, bob.rawValue, role: .read, in: team, by: alice, acting: team)
      let teams = try await agent(r, in: team)
      let bobs = try await cookie(r, bob, team)
      let host = "\(team.rawValue).space.test:5530"
      for (route, body) in [
        ("session", ["title": "helper", "provider": "testing", "model": "test-model"] as JSONValue),
        ("message", ["session": .string(teams.rawValue), "message": "hi"]),
      ] {
        let refused = try await post(r, host, route, body, cookie: bobs)
        #expect(refused.status == .forbidden, "\(route)")
        #expect(try await code(refused) == "groupForbidden", "\(route)")
      }
      #expect(try await r.harness.store.messages(conversation: ConversationID(teams.rawValue)).isEmpty)
    }
  }

  @Test func theDevSeatsPageCreatesAndPostsAsTheOwner() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: true, origin: "https://space.test:5530")
      let r = Rig(harness: harness, alice: AccountID(rawValue: "unused"), persona: "owner", aliceGroup: .shared)
      let made = try await post(
        r, r.sharedHost, "session", ["title": "helper", "provider": "testing", "model": "test-model", "message": "start"], cookie: "",
      )
      #expect(made.status == .ok)
      let id = try await created(made)
      #expect(try await harness.store.record(id).createdBy == "owner")
      let sent = try await post(r, r.sharedHost, "message", ["session": .string(id.rawValue), "message": "more"], cookie: "")
      #expect(sent.status == .ok)
      let messages = try await harness.store.messages(conversation: ConversationID(id.rawValue))
      #expect(messages.map(\.content.text) == ["start", "more"])
      #expect(messages.allSatisfy { $0.sender.id == "owner" })
    }
  }
}
