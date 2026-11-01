import ControlledTime
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import LiveDocument
import Serve
import ServeTesting
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing
import WmdDocument

@Suite
struct LiveRouteTests {
  @Test func aSocketSyncsTheDocumentAfterItsHello() async throws {
    let harness = try Harness()
    _ = try await harness.space.fs(.shared).write("/plan.wmd", Data("# Plan\n\nHello\n".utf8), ifMatch: nil)
    try await dial(harness, "/plan.wmd", create: false) { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case let .welcome(_, name, access, _, rev)? = try await control(inbound.next()) else {
        Issue.record("no welcome"); return
      }
      #expect(name == "dev" && access == .write && rev != nil)
      let replica = LiveReplica(.wmd)
      try await socket.send(.binary(LiveFrame.sync(versionVector: Array(replica.versionVector)).bytes))
      guard case let .binary(update)? = await inbound.next(), case let .update(bytes) = try LiveFrame(bytes: update) else {
        Issue.record("no catch-up"); return
      }
      try replica.importUpdate(Data(bytes))
      #expect(replica.text == "# Plan\n\nHello\n")
      guard case let .binary(synced)? = await inbound.next(), case .synced = try LiveFrame(bytes: synced) else {
        Issue.record("no synced"); return
      }
    }
  }

  @Test func aMissingDocumentOpensOnlyWhenTheHelloAsksToCreateIt() async throws {
    let harness = try Harness()
    try await dial(harness, "/new.wmd", create: false) { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case .error(code: .notFound, _)? = try await control(inbound.next()) else { Issue.record("a visit opened it"); return }
    }
    await #expect(throws: (any Error).self) { try await harness.space.fs(.shared).read("/new.wmd") }
    try await dial(harness, "/new.wmd", create: true) { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case .welcome? = try await control(inbound.next()) else { Issue.record("create was refused"); return }
    }
    #expect(try await harness.space.fs(.shared).read("/new.wmd").1.isEmpty)
  }

  @Test func aReadOnlyChannelRefusesAnUpdate() async throws {
    let harness = try Harness()
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let (reader, owner) = try await withSessionDeps {
      let reader = try await harness.space.sessions.createSession(group: .shared, title: "reader", kind: .task, createdBy: "owner", executor: model)
      let owner = try await harness.space.sessions.createSession(group: .shared, title: "owner", kind: .task, createdBy: "owner", executor: model)
      return (reader, owner)
    }
    let path = "/_/sessions/\(owner.rawValue)/notes.wmd"
    _ = try await harness.space.fs(.shared).write(path, Data("Hello\n".utf8), ifMatch: nil)
    try await SessionPrincipal.$current.withValue(GatedSession(session: reader, group: .shared, exec: false)) {
      try await readOnlyRefusal(harness, path)
    }
    #expect(try await harness.space.fs(.shared).read(path).1 == Data("Hello\n".utf8))
  }

  @Test func aSocketClosesWhenItsGroupGoesPrivate() async throws {
    let harness = try Harness()
    let team = GroupID(rawValue: "team")
    try await harness.space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at, visibility) VALUES (?, '2026-01-01T00:00:00Z', 'open')", arguments: [team.rawValue])
    }
    _ = try await harness.space.fs(team).write("/plan.wmd", Data("Hello\n".utf8), ifMatch: nil)
    try await dial(harness, "/plan.wmd?group=team") { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case .welcome(_, _, .write, _, _)? = try await control(inbound.next()) else {
        Issue.record("no writer's welcome"); return
      }
      try await harness.space.setVisibility(.private, of: team, by: .anonymous, acting: team)
      guard case .error(code: .forbidden, _)? = try await control(inbound.next()) else {
        Issue.record("a socket outlived its read access"); return
      }
      #expect(await inbound.next() == nil)
    }
  }

  private func readOnlyRefusal(_ harness: Harness, _ path: String) async throws {
    try await dial(harness, path) { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case let .welcome(_, _, access, _, _)? = try await control(inbound.next()) else {
        Issue.record("no welcome"); return
      }
      #expect(access == .read)
      let replica = LiveReplica(.wmd)
      try await socket.send(.binary(LiveFrame.sync(versionVector: Array(replica.versionVector)).bytes))
      while case let .binary(bytes)? = await inbound.next() {
        if case let .update(update) = try LiveFrame(bytes: bytes) { try replica.importUpdate(Data(update)) }
        if case .synced = try LiveFrame(bytes: bytes) { break }
      }
      let update = try #require(try replica.merge(text: "Hello there\n", base: nil, peer: 9)?.update)
      try await socket.send(.binary(LiveFrame.update(Array(update)).bytes))
      guard case .error(code: .readOnly, _)? = try await control(inbound.next()) else {
        Issue.record("a read-only channel took an update"); return
      }
    }
  }

  @Test func aSocketWithoutAHelloClosesAtTheDeadline() async throws {
    let clock = VirtualClock()
    let harness = try Harness(clock: clock)
    try await dial(harness, "/plan.wmd", hello: false) { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      try await clock.sleeping { $0 == liveHelloDeadline }
      await clock.advance(by: liveHelloDeadline)
      #expect(await inbound.next() == nil)
    }
  }

  @Test func theLegacyRouteRefusesInTheCodesItsClientsKnow() async throws {
    let harness = try Harness()
    _ = try await harness.space.fs(.shared).write("/plan.wmd", Data("# Plan\n".utf8), ifMatch: nil)
    _ = try await harness.space.fs(.shared).write("/notes.md", Data("notes\n".utf8), ifMatch: nil)
    try await dial(harness, "/plan.wmd", prefix: "/v1/wmd") { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case .welcome? = try await control(inbound.next()) else { Issue.record("no welcome"); return }
    }
    try await dial(harness, "/notes.md", prefix: "/v1/wmd") { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case let .text(text)? = await inbound.next(), let json = JSONValue.parse(text) else { Issue.record("no refusal"); return }
      let refusal = try JSONValueDecoder().decode(WmdError.self, from: json)
      #expect(refusal.type == "error" && refusal.code == .notWmd)
    }
    try await dial(harness, "/notes.md") { socket in
      var inbound = socket.inbound.makeAsyncIterator()
      guard case .error(code: .notLive, _)? = try await control(inbound.next()) else { Issue.record("no notLive"); return }
    }
  }

  /// An error frame as clients built before `.canvas` decode it: a closed set of codes.
  private struct WmdError: Decodable {
    enum Code: String, Decodable {
      case unauthorized, forbidden, notFound, notWmd, protocolViolation, readOnly, invalidUpdate, missingDependencies, `internal`
    }

    let type: String
    let code: Code
  }

  private func dial(
    _ harness: Harness, _ path: String, prefix: String = LiveChannel.routePrefix, create: Bool = false, group: String? = nil,
    hello: Bool = true,
    _ body: (WebSocket) async throws -> Void,
  ) async throws {
    var headers = RequestHeaders()
    headers.set("connection", "Upgrade")
    headers.set("upgrade", "websocket")
    headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    headers.set("sec-websocket-version", "13")
    let request = Request(url: URL(string: "http://space" + prefix + path)!, headers: headers)
    guard case let .webSocket(socket, serve) = try await ServeTesting.upgrade(harness.handler, request) else {
      Issue.record("\(path) did not upgrade"); return
    }
    try await withThrowingDiscardingTaskGroup { tasks in
      tasks.addTask { await serve() }
      if hello {
        let frame = LiveClientControl.hello(authorization: nil, group: group, peer: "7", create: create ? true : nil)
        try await socket.send(.text(try JSONValueEncoder().encode(frame).jsonString()))
      }
      try await body(socket)
      socket.close()
    }
  }

  private func control(_ message: WebSocketMessage?) throws -> LiveServerControl? {
    guard case let .text(text)? = message, let json = JSONValue.parse(text) else { return nil }
    return try JSONValueDecoder().decode(LiveServerControl.self, from: json)
  }
}
