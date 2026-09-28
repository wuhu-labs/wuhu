import Fetch
import Foundation
import JSONValue
import ServeTesting
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

// Where `GET /v1/groups` says the caller stands: the person is a member of
// alice (personal), shared and team; team reads library; bob is another
// person's.
@Suite struct GroupListTests {
  struct Space {
    let harness: SessionHarness
    let tokens: ExecTokens
    let bearer: String
    let alice: GroupID
    let bob: GroupID
  }

  static let team = GroupID(rawValue: "team")
  static let library = GroupID(rawValue: "library")

  func space(dev: Bool = false) async throws -> Space {
    let tokens = ExecTokens(spaceURL: "https://space.test:5530")
    let harness = try await SessionHarness(dev: dev, origin: "https://space.test:5530", execTokens: tokens)
    let (bearer, key) = try await harness.enrolledBearer()
    let alice = try await harness.space.ensurePersonalGroup(account: key.account)
    let bob = try await harness.space.ensurePersonalGroup(account: try await harness.space.addAccount(kind: .human, name: nil).id)
    try await harness.space.writer.write { db in
      for group in [Self.team, Self.library] {
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2030-01-01T00:00:00.000Z')", arguments: [group.rawValue])
      }
      try db.execute(
        sql: "INSERT INTO group_members (grp, account_id, joined_at) VALUES (?, ?, '2030-01-01T00:00:00.000Z')",
        arguments: [Self.team.rawValue, key.account.rawValue],
      )
    }
    try await harness.space.addEdge(src: Self.team, dst: Self.library, kind: .read, by: nil)
    return Space(harness: harness, tokens: tokens, bearer: bearer, alice: alice, bob: bob)
  }

  func sessionToken(_ s: Space, in group: GroupID) async throws -> String {
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let session = try await s.harness.store.createSession(group: group, title: "a", kind: .agent, createdBy: "owner", executor: model)
    let exec = try await s.harness.space.mintExec(machine: try await s.harness.space.addMachine(name: "box-\(group.rawValue)").id, caller: session.rawValue)
    return s.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
  }

  func list(_ s: Space, host: String = "space.test", group: GroupID? = nil, bearer: String?) async throws -> Response {
    var request = Request(url: URL(string: "https://\(host)/v1/groups")!)
    if let bearer { request.headers[.authorization] = "Bearer " + bearer }
    if let group { request.headers[GroupHeader.name] = group.rawValue }
    return try await s.harness.api(request)
  }

  func standing(_ s: Space, host: String = "space.test", group: GroupID? = nil, bearer: String?) async throws -> [String: String] {
    let response = try await list(s, host: host, group: group, bearer: bearer)
    #expect(response.status == .ok)
    let listed = try JSONValueDecoder().decode([GroupSummary].self, from: try await json(response))
    return Dictionary(uniqueKeysWithValues: listed.map { summary in
      (summary.id, [summary.member == true ? "member" : nil, summary.readable == true ? "readable" : nil].compactMap(\.self).joined(separator: "+"))
    })
  }

  @Test func aPersonIsAMemberOfExactlyItsGroupsAndReadsTheUnionOfWhatTheyRead() async throws {
    try await withSessionDeps {
      let s = try await space()
      #expect(try await standing(s, bearer: s.bearer) == [
        "shared": "member+readable", s.alice.rawValue: "member+readable", "team": "member+readable",
        "library": "readable", s.bob.rawValue: "",
      ])
    }
  }

  @Test func aSessionIsAMemberOfItsOwnGroupAndReadsWhatItReads() async throws {
    try await withSessionDeps {
      let s = try await space()
      #expect(try await standing(s, bearer: try await sessionToken(s, in: s.alice)) == [
        "shared": "readable", s.alice.rawValue: "member+readable", "team": "", "library": "", s.bob.rawValue: "",
      ])
      #expect(try await standing(s, bearer: try await sessionToken(s, in: Self.team)) == [
        "shared": "", s.alice.rawValue: "", "team": "member+readable", "library": "readable", s.bob.rawValue: "",
      ])
    }
  }

  @Test func anAnonymousCallerGetsEveryGroupAndNoStanding() async throws {
    try await withSessionDeps {
      let s = try await space()
      #expect(try await standing(s, bearer: nil) == [
        "shared": "", s.alice.rawValue: "", "team": "", "library": "", s.bob.rawValue: "",
      ])
      let forged = try await list(s, bearer: "not-an-assertion")
      #expect(forged.status == .unauthorized)
    }
  }

  @Test func theDevSeatActsInEveryGroup() async throws {
    try await withSessionDeps {
      let s = try await space(dev: true)
      #expect(try await standing(s, bearer: nil) == [
        "shared": "member+readable", s.alice.rawValue: "member+readable", "team": "member+readable",
        "library": "member+readable", s.bob.rawValue: "member+readable",
      ])
      #expect(try await standing(s, bearer: s.bearer)[s.bob.rawValue] == "")
    }
  }

  // Readable is not actable: a group read but not joined is reached only by
  // a member group's hostful paths.
  @Test func aReadableGroupThePersonIsNotAMemberOfIsReachedOnlyByAddress() async throws {
    try await withSessionDeps {
      let s = try await space()
      _ = try await s.harness.space.fs(Self.library).write("/book.md", Data("book".utf8), ifMatch: nil)
      func read(_ path: String, group: GroupID) async throws -> Response {
        var request = Request(
          url: URL(string: "https://space.test/v1/tools/read")!, method: .post,
          body: .bytes(Data(JSONValue.object(["path": .string(path)]).jsonString().utf8), contentType: "application/json"),
        )
        request.headers[.authorization] = "Bearer " + s.bearer
        request.headers[GroupHeader.name] = group.rawValue
        return try await s.harness.api(request)
      }
      let named = try await read("/book.md", group: Self.library)
      #expect(named.status == .forbidden)
      #expect(try await json(named).object?["code"]?.stringValue == "groupForbidden")

      let web = ServeTesting.client(SpaceServer.webHandler(
        space: s.harness.space, apiPort: 5530, advertisedOrigin: "https://space.test:5530", dev: false,
      ))
      var mint = Request(url: URL(string: "https://library.space.test:5531/_/session")!, method: .post)
      mint.headers[.authorization] = "Bearer " + s.bearer
      let minted = try await web(mint)
      #expect(minted.status == .forbidden)
      #expect(try await json(minted).object?["code"]?.stringValue == "groupForbidden")
      #expect(minted.headers[.setCookie] == nil)

      let hostful = try await read("wuhu://library.localspace/book.md", group: Self.team)
      #expect(hostful.status == .ok)
      #expect(try await hostful.text().contains("book"))
    }
  }

  @Test func aSessionNamingAnotherGroupIsRefusedByTheGate() async throws {
    try await withSessionDeps {
      let s = try await space()
      let refused = try await list(s, group: .shared, bearer: try await sessionToken(s, in: s.alice))
      #expect(refused.status == .forbidden)
      #expect(try await json(refused).object?["code"]?.stringValue == "groupMismatch")
    }
  }

  @Test func theGroupARequestNamesChangesNothing() async throws {
    try await withSessionDeps {
      let s = try await space()
      let bare = try await standing(s, bearer: s.bearer)
      #expect(try await standing(s, host: "team.space.test", bearer: s.bearer) == bare)
      #expect(try await standing(s, host: "\(s.bob.rawValue).space.test", bearer: s.bearer) == bare)
      #expect(try await standing(s, group: s.bob, bearer: s.bearer) == bare)
      #expect(try await standing(s, host: "team.space.test", group: s.alice, bearer: s.bearer) == bare)
      #expect(try await standing(s, host: "library.space.test", bearer: nil) == standing(s, bearer: nil))
      let token = try await sessionToken(s, in: s.alice)
      #expect(try await standing(s, host: "\(s.alice.rawValue).space.test", bearer: token) == standing(s, bearer: token))
    }
  }
}
