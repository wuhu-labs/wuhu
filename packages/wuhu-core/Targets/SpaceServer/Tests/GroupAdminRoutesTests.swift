import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import ServeTesting
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

// The group admin surface: open/private, a private group's list, and the
// secrets switch, over HTTP as a person.
@Suite(.deterministicDependencies) struct GroupAdminRoutesTests {
  struct World {
    let harness: SessionHarness
    let tokens: ExecTokens
    let bearer: String
    let account: AccountID
    let group: GroupID
  }

  func world() async throws -> World {
    let tokens = ExecTokens(spaceURL: "http://space")
    let harness = try await SessionHarness(dev: false, origin: "https://space.test:5530", execTokens: tokens)
    let (bearer, key) = try await harness.enrolledBearer()
    let group = GroupID(rawValue: "studio")
    try await harness.space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('studio', '2030-01-01T00:00:00Z')")
    }
    try await harness.space.setGrant(.account, key.account.rawValue, role: .admin, in: group, by: .anonymous, acting: group)
    return World(harness: harness, tokens: tokens, bearer: bearer, account: key.account, group: group)
  }

  func send(_ w: World, _ method: Fetch.Method, _ path: String, _ body: JSONValue? = nil) async throws -> Response {
    var request = Request(url: URL(string: "https://space.test\(path)")!, method: method)
    request.headers[.authorization] = "Bearer " + w.bearer
    if let body {
      request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    }
    return try await w.harness.api(request)
  }

  @Test func aMemberCreatesRenamesAndReachesAGroupByIDAndAlias() async throws {
    try await withSessionDeps {
      let w = try await world()
      let response = try await send(w, .post, "/v1/groups", ["alias": "research_notes"])
      #expect(response.status == .created)
      let created = try await response.json(GroupDetail.self)
      let id = created.id
      #expect(created.alias == "research_notes")
      #expect(created.open)
      #expect(created.entries == [GroupAccessEntry(kind: "account", id: w.account.rawValue, role: "admin")])
      #expect(id.split(separator: "-").count == 3)
      let listed = try await send(w, .get, "/v1/groups").json(JSONValue.self)
      let summary = try #require(listed.array?.first { $0.object?["id"] == .string(id) }?.object)
      #expect(Set(summary.keys) == ["id", "member", "readable", "admin"])
      let detail = try await send(w, .get, "/v1/group/research_notes").json(GroupDetail.self)
      #expect(detail.id == id)
      #expect(detail.alias == "research_notes")
      #expect(detail.open)
      #expect(detail.entries == [GroupAccessEntry(kind: "account", id: w.account.rawValue, role: "admin")])
      let changed = try await send(w, .put, "/v1/group/research_notes", ["alias": "science"]).json(GroupDetail.self)
      #expect(changed.id == id)
      #expect(changed.alias == "science")
      #expect(try await send(w, .get, "/v1/group/research_notes").json(GroupDetail.self) == changed)
      #expect(try await send(w, .get, "/v1/group/\(id)").json(GroupDetail.self) == changed)
      #expect(try await send(w, .post, "/v1/groups", ["alias": "research_notes"]).status == .conflict)
      #expect(try await send(w, .post, "/v1/groups", ["alias": "has-hyphens"]).status == .badRequest)
      let guest = try await w.harness.space.addAccount(kind: .human, name: "Guest", guest: true)
      let bearer = try await w.harness.enrolledBearer(account: guest.id).bearer
      var request = Request(url: URL(string: "https://space.test/v1/groups")!, method: .post)
      request.headers[.authorization] = "Bearer " + bearer
      request.body = try .json(["alias": "guest_space"])
      let refused = try await w.harness.api(request)
      #expect(refused.status == .forbidden)
      #expect(try await refused.json(JSONValue.self).object?["code"] == "memberRequired")
    }
  }

  @Test func anonymousCreationPassesThroughTheBearerWall() async throws {
    try await withSessionDeps {
      let w = try await world()
      let request = Request(url: URL(string: "https://space.test/v1/groups")!, method: .post, body: try .json(["alias": "research"]))
      #expect(try await w.harness.api(request).status == .unauthorized)
      #expect(try await w.harness.space.resolveGroup("research") == nil)
    }
  }

  @Test func aSessionExecCannotCreateAGroupEvenWithAnEligibleOwner() async throws {
    try await withSessionDeps {
      let w = try await world()
      let session = try await w.harness.store.createSession(group: .shared, title: "Creator", kind: .agent, createdBy: "person", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      let machine = (try await w.harness.space.addMachineV2(name: "box")).machine
      let exec = try await w.harness.space.mintExec(machine: machine.id, caller: session.rawValue)
      let bearer = w.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
      var request = Request(url: URL(string: "https://space.test/v1/groups")!, method: .post, body: try .json(["alias": "research_notes", "owner": w.account.rawValue]))
      request.headers[.authorization] = "Bearer " + bearer
      let response = try await w.harness.api(request)
      #expect(response.status == .forbidden)
      #expect(try await response.text().contains("run_script"))
      #expect(try await w.harness.space.resolveGroup("research_notes") == nil)
    }
  }

  @Test func anAdminOpensTheGroupAddsAPersonToListAndSwitchesSecrets() async throws {
    try await withSessionDeps {
      let w = try await world()
      let detail = try await send(w, .get, "/v1/group/\(w.group.rawValue)").json(GroupDetail.self)
      #expect(detail.open == false)
      #expect(detail.secrets == "owner")

      let opened = try await send(w, .put, "/v1/group/\(w.group.rawValue)", ["open": .bool(true)]).json(GroupDetail.self)
      #expect(opened.open == true)
      #expect(try await w.harness.space.group(w.group)?.visibility == .open)

      let guest = try await w.harness.space.addAccount(kind: .human, name: "guest", guest: true)
      let added = try await send(
        w, .put, "/v1/group/\(w.group.rawValue)/access",
        ["kind": "account", "id": .string(guest.id.rawValue), "role": "read"],
      )
      #expect(added.status == .ok)
      let listed = try await send(w, .get, "/v1/group/\(w.group.rawValue)").json(GroupDetail.self)
      #expect(listed.entries.sorted { $0.id < $1.id } == [
        GroupAccessEntry(kind: "account", id: w.account.rawValue, role: "admin"),
        GroupAccessEntry(kind: "account", id: guest.id.rawValue, role: "read"),
      ].sorted { $0.id < $1.id })

      let reachable = try await send(w, .put, "/v1/group/\(w.group.rawValue)", ["secrets": "reachable"]).json(GroupDetail.self)
      #expect(reachable.secrets == "reachable")

      let removed = try await send(w, .delete, "/v1/group/\(w.group.rawValue)/access?kind=account&id=\(guest.id.rawValue)")
      #expect(removed.status == .ok)
      #expect(try await send(w, .get, "/v1/group/\(w.group.rawValue)").json(GroupDetail.self).entries.map(\.id) == [w.account.rawValue])
    }
  }

  @Test func theListIsTheGroupsPeoplesAndNobodyElses() async throws {
    try await withSessionDeps {
      let w = try await world()
      let guest = try await w.harness.space.addAccount(kind: .human, name: "guest", guest: true)
      _ = try await send(
        w, .put, "/v1/group/\(w.group.rawValue)/access", ["kind": "account", "id": .string(guest.id.rawValue), "role": "read"],
      )
      let stranger = try await w.harness.space.addAccount(kind: .human, name: "stranger")
      let strangerBearer = try await w.harness.enrolledBearer(account: stranger.id).bearer
      var request = Request(url: URL(string: "https://space.test/v1/group/\(w.group.rawValue)")!, method: .get)
      request.headers[.authorization] = "Bearer " + strangerBearer
      #expect(try await w.harness.api(request).status == .notFound)
    }
  }

  @Test func aPersonalGroupTakesNoListAndTheSettingsGroupNoVisibility() async throws {
    try await withSessionDeps {
      let w = try await world()
      let own = try #require(try await w.harness.space.personalGroup(of: w.account))
      let personal = try await send(w, .put, "/v1/group/\(own.rawValue)", ["open": .bool(true)])
      #expect(personal.status == .forbidden)
      let entries = try await send(
        w, .put, "/v1/group/\(own.rawValue)/access", ["kind": "account", "id": .string(w.account.rawValue), "role": "read"],
      )
      #expect(entries.status == .forbidden)
      let settings = try await send(w, .put, "/v1/group/settings", ["open": .bool(true)])
      #expect(settings.status == .forbidden)
    }
  }

  @Test func theSettingsGroupsListIsTheAccountAdminVerbsAlone() async throws {
    try await withSessionDeps {
      let w = try await world()
      let root = try await w.harness.space.addAccount(kind: .human, name: "root", admin: true)
      let bearer = try await w.harness.enrolledBearer(account: root.id).bearer
      func call(_ method: Fetch.Method, _ path: String, _ body: JSONValue? = nil) async throws -> Response {
        var request = Request(url: URL(string: "https://space.test\(path)")!, method: method)
        request.headers[.authorization] = "Bearer " + bearer
        if let body {
          request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
        }
        return try await w.harness.api(request)
      }
      let granted = try await call(
        .put, "/v1/group/settings/access", ["kind": "account", "id": .string(w.account.rawValue), "role": "admin"],
      )
      #expect(granted.status == .forbidden)
      #expect(try await granted.text().contains("adminRequired"))
      let revoked = try await call(.delete, "/v1/group/settings/access?kind=account&id=\(root.id.rawValue)")
      #expect(revoked.status == .forbidden)
      #expect(try await w.harness.space.isHumanAdmin(root.id, of: .settings))
    }
  }

  @Test func anAdminNamesOnlyLiveAccountsAndGroups() async throws {
    try await withSessionDeps {
      let w = try await world()
      let missing = try await send(
        w, .put, "/v1/group/\(w.group.rawValue)/access", ["kind": "account", "id": "ac_nosuch00", "role": "read"],
      )
      #expect(missing.status == .notFound)
      let role = try await send(
        w, .put, "/v1/group/\(w.group.rawValue)/access", ["kind": "account", "id": .string(w.account.rawValue), "role": "owner"],
      )
      #expect(role.status == .badRequest)
    }
  }
}
