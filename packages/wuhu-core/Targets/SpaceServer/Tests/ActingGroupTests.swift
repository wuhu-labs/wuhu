import Fetch
import FetchSSE
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

// The group a request acts in: a person names it by header or Host and needs
// membership; a session acts in its own group only.
@Suite struct ActingGroupTests {
  struct People {
    let harness: SessionHarness
    let bearer: String
    let alice: GroupID
    let bob: GroupID
  }

  func people(tokens: ExecTokens? = nil) async throws -> People {
    let harness = try await SessionHarness(dev: false, origin: "https://space.test:5530", execTokens: tokens)
    let (bearer, key) = try await harness.enrolledBearer()
    let alice = try await harness.space.ensurePersonalGroup(account: key.account)
    let bob = try await harness.space.ensurePersonalGroup(account: try await harness.space.addAccount(kind: .human, name: nil).id)
    return People(harness: harness, bearer: bearer, alice: alice, bob: bob)
  }

  func write(
    _ people: People, _ path: String, host: String = "space.test", group: String? = nil, bearer: String? = nil,
  ) async throws -> Response {
    var request = Request(
      url: URL(string: "https://\(host)/v1/tools/write")!, method: .post,
      body: .bytes(Data(JSONValue.object(["path": .string(path), "content": "x"]).jsonString().utf8), contentType: "application/json"),
    )
    request.headers[.authorization] = "Bearer " + (bearer ?? people.bearer)
    if let group { request.headers[GroupHeader.name] = group }
    return try await people.harness.api(request)
  }

  func code(_ response: Response) async throws -> String? {
    try await json(response).object?["code"]?.stringValue
  }

  @Test func aPersonActsInTheGroupItNamesByHeaderOrHost() async throws {
    try await withSessionDeps {
      let p = try await people()
      #expect(try await write(p, "/by-header.md", group: p.alice.rawValue).status == .ok)
      #expect(try await write(p, "/by-host.md", host: "\(p.alice.rawValue).space.test").status == .ok)
      #expect(try await write(p, "/plain.md").status == .ok)
      let alice = await p.harness.space.fs(p.alice)
      #expect(try await alice.stat("/by-header.md").size == 1)
      #expect(try await alice.stat("/by-host.md").size == 1)
      #expect(try await p.harness.space.fs(.shared).stat("/plain.md").size == 1)
      await #expect(throws: (any Error).self) { try await p.harness.space.fs(.shared).stat("/by-header.md") }
    }
  }

  @Test func aGroupThePersonCannotActInIsRefusedWithItsReason() async throws {
    try await withSessionDeps {
      let p = try await people()
      let foreign = try await write(p, "/x.md", group: p.bob.rawValue)
      #expect(foreign.status == .forbidden)
      #expect(try await code(foreign) == "groupForbidden")
      let unknown = try await write(p, "/x.md", group: "nowhere")
      #expect(unknown.status == .notFound)
      #expect(try await code(unknown) == "unknownGroup")
      let conflict = try await write(p, "/x.md", host: "\(p.bob.rawValue).space.test", group: p.alice.rawValue)
      #expect(conflict.status == .badRequest)
      #expect(try await code(conflict) == "groupConflict")
    }
  }

  @Test func anExecTokenNamingAnotherGroupIsRefused() async throws {
    try await withSessionDeps {
      let tokens = ExecTokens(spaceURL: "https://space.test:5530")
      let p = try await people(tokens: tokens)
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let session = try await p.harness.store.createSession(group: p.alice, title: "a", kind: .agent, createdBy: "owner", executor: model)
      let machine = try await p.harness.space.addMachine(name: "box")
      let exec = try await p.harness.space.mintExec(machine: machine.id, caller: session.rawValue)
      let token = tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
      let mismatched = try await write(p, "/x.md", group: GroupID.shared.rawValue, bearer: token)
      #expect(mismatched.status == .forbidden)
      #expect(try await code(mismatched) == "groupMismatch")
      #expect(try await write(p, "/own.md", group: p.alice.rawValue, bearer: token).status == .ok)
      #expect(try await write(p, "/unnamed.md", bearer: token).status == .ok)
      let alice = await p.harness.space.fs(p.alice)
      #expect(try await alice.stat("/own.md").size == 1)
      #expect(try await alice.stat("/unnamed.md").size == 1)

      let foreignHost = try await write(p, "/x.md", host: "\(p.bob.rawValue).space.test", bearer: token)
      #expect(foreignHost.status == .forbidden)
      #expect(try await code(foreignHost) == "groupMismatch")
      #expect(try await write(p, "/by-own-host.md", host: "\(p.alice.rawValue).space.test", bearer: token).status == .ok)

      let home = "/_/sessions/\(session.rawValue)/notes.md"
      #expect(try await write(p, home, bearer: token).status == .ok)
      let elsewhere = try await write(p, "wuhu://shared.localspace\(home)", bearer: token)
      #expect(elsewhere.status == .unprocessableContent)
      await #expect(throws: (any Error).self) { try await p.harness.space.fs(.shared).stat(home) }
    }
  }

  @Test func theByteLaneReadsAndWritesTheGroupItActsIn() async throws {
    try await withSessionDeps {
      let p = try await people()
      func file(_ method: Fetch.Method, group: String?) async throws -> Response {
        var request = Request(url: URL(string: "https://space.test/v1/f/lane.bin")!, method: method)
        if method == .put { request.body = .bytes(Data("bytes".utf8), contentType: "application/octet-stream") }
        request.headers[.authorization] = "Bearer " + p.bearer
        if let group { request.headers[GroupHeader.name] = group }
        return try await p.harness.api(request)
      }
      #expect(try await file(.put, group: p.alice.rawValue).status == .ok)
      #expect(try await p.harness.space.fs(p.alice).read("/lane.bin").1 == Data("bytes".utf8))
      #expect(try await file(.get, group: nil).status == .notFound)
      let read = try await file(.get, group: p.alice.rawValue)
      #expect(read.status == .ok)
      #expect(try await read.text() == "bytes")
      #expect(try await file(.get, group: p.bob.rawValue).status == .forbidden)
    }
  }

  @Test func theByteLaneNamesAnotherReadableGroupByQuery() async throws {
    try await withSessionDeps {
      let p = try await people()
      _ = try await p.harness.space.fs(.shared).write("/common.bin", Data("shared".utf8), ifMatch: nil)
      _ = try await p.harness.space.fs(p.alice).write("/hers.bin", Data("alice".utf8), ifMatch: nil)
      func get(_ path: String, group: String?) async throws -> Response {
        var request = Request(url: URL(string: "https://space.test/v1/f\(path)")!)
        request.headers[.authorization] = "Bearer " + p.bearer
        if let group { request.headers[GroupHeader.name] = group }
        return try await p.harness.api(request)
      }
      let readable = try await get("/common.bin?group=shared", group: p.alice.rawValue)
      #expect(readable.status == .ok)
      #expect(try await readable.text() == "shared")
      let unreadable = try await get("/hers.bin?group=\(p.alice.rawValue)", group: nil)
      #expect(unreadable.status == .notFound)
      #expect(try await code(unreadable) == "notFound")
      #expect(try await get("/hers.bin?group=No%2FSuch", group: nil).status == .badRequest)
    }
  }

  @Test func theWebOriginStreamsOnlySharedWhilePersonalGroupsWrite() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let alice = try await harness.space.ensurePersonalGroup(account: account.id)
    _ = try await harness.space.fs(alice).write("/hers-1.md", Data("x".utf8), ifMatch: nil)
    _ = try await harness.space.fs(.shared).write("/common-1.md", Data("x".utf8), ifMatch: nil)
    let response = try await harness.get(harness.web, "/_/observe", query: ["glob": "**", "from": "0"])
    #expect(response.status == .ok)
    var paths: [String] = []
    for try await frame in response.sse() {
      let event = try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data)))
      guard case let .write(path, _, _) = event else { Issue.record("\(event)"); break }
      paths.append(path)
      if paths.count == 1 {
        _ = try await harness.space.fs(alice).write("/hers-2.md", Data("x".utf8), ifMatch: nil)
        _ = try await harness.space.fs(.shared).write("/common-2.md", Data("x".utf8), ifMatch: nil)
      }
      if paths.count == 2 { break }
    }
    #expect(paths == ["/common-1.md", "/common-2.md"])
  }

  @Test func aPostAttachesFilesFromTheGroupItActsIn() async throws {
    try await withSessionDeps {
      let p = try await people()
      _ = try await p.harness.space.fs(p.alice).write("/mine.md", Data("mine".utf8), ifMatch: nil)
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let box = try await p.harness.store.createSession(group: p.alice, title: "a", kind: .agent, createdBy: "owner", executor: model)
      func post(group: String?) async throws -> Response {
        var request = Request(
          url: URL(string: "https://space.test/v1/conversation/message")!, method: .post,
          body: .bytes(Data(JSONValue.object([
            "message": "look", "session": .string(box.rawValue), "attachments": ["/mine.md"],
          ]).jsonString().utf8), contentType: "application/json"),
        )
        request.headers[.authorization] = "Bearer " + p.bearer
        if let group { request.headers[GroupHeader.name] = group }
        return try await p.harness.api(request)
      }
      #expect(try await post(group: nil).status == .notFound)
      let inAlice = try await post(group: p.alice.rawValue)
      let text = try await inAlice.text()
      #expect(inAlice.status == .ok, "\(text)")
      #expect(try await post(group: p.bob.rawValue).status == .forbidden)
    }
  }

  @Test func aPostAttachesAQualifiedFileOfAReadableGroupAndReadersGetPathsThatResolve() async throws {
    try await withSessionDeps {
      let p = try await people()
      _ = try await p.harness.space.fs(.shared).write("/common.md", Data("common".utf8), ifMatch: nil)
      _ = try await p.harness.space.fs(p.bob).write("/his.md", Data("his".utf8), ifMatch: nil)
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let box = try await p.harness.store.createSession(group: .shared, title: "s", kind: .agent, createdBy: "owner", executor: model)
      func post(_ attachment: String, group: String) async throws -> Response {
        var request = Request(
          url: URL(string: "https://space.test/v1/conversation/message")!, method: .post,
          body: .bytes(Data(JSONValue.object([
            "message": "look", "session": .string(box.rawValue), "attachments": .array([.string(attachment)]),
          ]).jsonString().utf8), contentType: "application/json"),
        )
        request.headers[.authorization] = "Bearer " + p.bearer
        request.headers[GroupHeader.name] = group
        return try await p.harness.api(request)
      }
      let posted = try await post("wuhu://shared.localspace/common.md", group: p.alice.rawValue)
      let postedText = try await posted.text()
      #expect(posted.status == .ok, "\(postedText)")
      let unread = try await post("wuhu://\(p.bob.rawValue).localspace/his.md", group: p.alice.rawValue)
      #expect(unread.status == .notFound)
      #expect(try await code(unread) == "notFound")

      func attachments(as group: String) async throws -> [String] {
        var request = Request(url: URL(string: "https://space.test/v1/conversation/\(box.rawValue)/messages")!)
        request.headers[.authorization] = "Bearer " + p.bearer
        request.headers[GroupHeader.name] = group
        let read = try JSONValueDecoder().decode(ConversationReadOutput.self, from: try await json(try await p.harness.api(request)))
        return read.messages.flatMap { $0.attachments ?? [] }.map(\.path)
      }
      let hostless = try #require(try await attachments(as: GroupID.shared.rawValue).first)
      #expect(hostless.hasPrefix("/_/conversations/\(box.rawValue)/attachments/"))
      #expect(try await p.harness.space.fs(.shared).read(hostless).1 == Data("common".utf8))
      #expect(try await attachments(as: p.alice.rawValue) == ["wuhu://shared.localspace" + hostless])
      // One parser for every group address: a host is compared lowercased, and
      // a .localspace host naming no group is malformed, not missing.
      let upper = try await post("wuhu://Shared.localspace/common.md", group: p.alice.rawValue)
      #expect(upper.status == .ok)
      for malformed in ["wuhu://localspace/common.md", "wuhu://Bad_Id.localspace/common.md"] {
        let refused = try await post(malformed, group: p.alice.rawValue)
        #expect(refused.status == .badRequest, "\(malformed)")
        #expect(try await code(refused) == "invalidArgument")
      }
      var file = Request(url: URL(string: "https://space.test/v1/f/common.md?group=Shared")!)
      file.headers[.authorization] = "Bearer " + p.bearer
      file.headers[GroupHeader.name] = p.alice.rawValue
      let fetched = try await p.harness.api(file)
      #expect(fetched.status == .ok, "?group= takes what a group host takes")
      #expect(try await fetched.text() == "common")
    }
  }

  @Test func theServerAdvertisesGroupsAndListsThemWithoutACredential() async throws {
    try await withSessionDeps {
      let p = try await people()
      let server = try JSONValueDecoder().decode(ServerInfo.self, from: try await json(try await p.harness.get("/v1/server")))
      #expect(server.features?.contains(GroupHeader.feature) == true)
      #expect(server.group == GroupID.shared.rawValue)
      let listed = try JSONValueDecoder().decode([GroupSummary].self, from: try await json(try await p.harness.get("/v1/groups")))
      #expect(Set(listed.map(\.id)) == [GroupID.shared.rawValue, p.alice.rawValue, p.bob.rawValue])
    }
  }

  @Test func aGroupObservesAnotherItReadsByTheQualifiedForm() async throws {
    try await withSessionDeps {
      let p = try await people()
      func observe(_ glob: String) async throws -> Response {
        var components = URLComponents(string: "https://\(p.alice.rawValue).space.test/v1/observe")!
        components.queryItems = [URLQueryItem(name: "glob", value: glob)]
        var request = Request(url: components.url!)
        request.headers[.authorization] = "Bearer " + p.bearer
        return try await p.harness.api(request)
      }
      #expect(try await observe("wuhu://\(p.bob.rawValue).localspace/**").status == .notFound)
      let response = try await observe("wuhu://shared.localspace/**")
      #expect(response.status == .ok)
      #expect(try await write(p, "/mine.md", group: p.alice.rawValue).status == .ok)
      #expect(try await write(p, "/common.md").status == .ok)
      for try await frame in response.sse() {
        let event = try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data)))
        guard case let .write(path, _, _) = event else { Issue.record("\(event)"); break }
        #expect(path == "wuhu://shared.localspace/common.md")
        break
      }
    }
  }
}
