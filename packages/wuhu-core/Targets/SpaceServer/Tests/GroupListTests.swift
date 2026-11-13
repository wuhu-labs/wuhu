import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import LoopCore
import ServeTesting
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

// Where `GET /v1/groups` says the caller stands: the person is a member of
// alice, shared and team; team reads library; bob is another private group.
@Suite(.deterministicDependencies) struct GroupListTests {
  struct Space {
    let harness: SessionHarness
    let tokens: ExecTokens
    let bearer: String
    let account: AccountID
    let alice: GroupID
    let bob: GroupID
  }

  static let team = GroupID(rawValue: "team")
  static let library = GroupID(rawValue: "library")

  func space(dev: Bool = false) async throws -> Space {
    let harness = try await SessionHarness(dev: dev, origin: "https://space.test:5530", spaceURL: "https://space.test:5530")
    let tokens = harness.runtime.tokens
    let (bearer, key) = try await harness.enrolledBearer()
    let alice = try await harness.space.privateGroup(account: key.account)
    let bob = try await harness.space.privateGroup(account: try await harness.space.addAccount(kind: .human, name: nil).id)
    for group in [Self.team, Self.library] { try await harness.space.seedGroup(group) }
    try await harness.space.setGrant(
      .account, key.account.rawValue, role: .write, in: Self.team, by: (try await harness.space.ensureDevPerson()).actor, acting: Self.team,
    )
    try await harness.space.setGrant(.group, Self.team.rawValue, role: .write, in: Self.library, by: (try await harness.space.ensureDevPerson()).actor, acting: Self.library)
    return Space(harness: harness, tokens: tokens, bearer: bearer, account: key.account, alice: alice, bob: bob)
  }

  func sessionToken(_ s: Space, in group: GroupID) async throws -> String {
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let session = try await s.harness.store.createSession(group: group, title: "a", kind: .agent, createdBy: "owner", executor: model)
    let exec = try await s.harness.space.reserveExec(machine: (try await s.harness.space.addMachineV2(name: "box_\(group.rawValue.replacingOccurrences(of: "-", with: "_"))")).machine.id, caller: session.rawValue)
    return try await s.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
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
        "shared": "member+readable", "team": "member+readable", "library": "",
        s.alice.rawValue: "member+readable", s.bob.rawValue: "",
      ])
    }
  }

  @Test func aSessionIsAMemberOfItsOwnGroupAndReadsWhatItReads() async throws {
    try await withSessionDeps {
      let s = try await space()
      #expect(try await standing(s, bearer: try await sessionToken(s, in: s.alice)) == [
        "shared": "readable", "team": "", "library": "",
        s.alice.rawValue: "member+readable", s.bob.rawValue: "",
      ])
      #expect(try await standing(s, bearer: try await sessionToken(s, in: Self.team)) == [
        "shared": "readable", "team": "member+readable", "library": "readable",
        s.alice.rawValue: "", s.bob.rawValue: "",
      ])
    }
  }

  @Test func anAnonymousCallerGetsEveryGroupAndNoStanding() async throws {
    try await withSessionDeps {
      let s = try await space()
      #expect(try await standing(s, bearer: nil) == [
        "shared": "", "team": "", "library": "",
        s.alice.rawValue: "", s.bob.rawValue: "",
      ])
      let forged = try await list(s, bearer: "not-an-assertion")
      #expect(forged.status == .unauthorized)
    }
  }

  @Test func theDevSeatActsInEveryGroup() async throws {
    try await withSessionDeps {
      let s = try await space(dev: true)
      #expect(try await standing(s, bearer: nil) == [
        "shared": "member+readable", "team": "member+readable", "library": "member+readable",
        s.alice.rawValue: "member+readable", s.bob.rawValue: "member+readable",
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

      var mint = Request(url: URL(string: "https://library.space.test:5530/_/session")!, method: .post)
      mint.headers[.authorization] = "Bearer " + s.bearer
      let minted = try await s.harness.api(mint)
      #expect(minted.status == .forbidden)
      #expect(try await json(minted).object?["code"]?.stringValue == "groupForbidden")
      #expect(minted.headers[.setCookie] == nil)

      let hostful = try await read("wuhu://library.localspace/book.md", group: Self.team)
      #expect(hostful.status == .ok)
      #expect(try await hostful.text().contains("book"))
    }
  }

  func administered(_ s: Space, bearer: String?) async throws -> Set<String> {
    let response = try await list(s, bearer: bearer)
    #expect(response.status == .ok)
    let listed = try JSONValueDecoder().decode([GroupSummary].self, from: try await json(response))
    return Set(listed.filter { $0.admin == true }.map(\.id))
  }

  // `admin` follows `is_admin`: a person through an admin edge from a group
  // they belong to, a live top-level agent in its own group.
  @Test func adminNamesTheGroupsTheCallerAdministers() async throws {
    try await withSessionDeps {
      let s = try await space()
      #expect(try await administered(s, bearer: s.bearer) == [s.alice.rawValue])
      _ = try await s.harness.space.setAdmin(s.account, admin: true)
      #expect(try await administered(s, bearer: s.bearer) == ["shared", "team", "library", s.alice.rawValue, s.bob.rawValue])
      #expect(try await administered(s, bearer: try await sessionToken(s, in: Self.team)) == ["team"])
      #expect(try await administered(s, bearer: nil) == [])
      let dev = try await space(dev: true)
      #expect(try await administered(dev, bearer: nil) == ["shared", "team", "library", dev.alice.rawValue, dev.bob.rawValue])
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
      #expect(try await standing(s, group: s.bob, bearer: s.bearer) == bare)
      #expect(try await standing(s, group: s.alice, bearer: s.bearer) == bare)
      let token = try await sessionToken(s, in: s.alice)
      #expect(try await standing(s, group: s.alice, bearer: token) == standing(s, bearer: token))
    }
  }
}
