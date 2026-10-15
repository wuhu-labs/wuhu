import Dependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import Serve
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

private let bound: Duration = .seconds(5)

@Suite struct KeyStreamsTests {
  @Test func selfRevocationEndsTheKeysStreamsAndSparesAnotherKeys() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (a, aKey) = try await harness.enrolledBearer()
      let (b, bKey) = try await harness.enrolledBearer()
      let bPersona = try await harness.space.mintPersona(key: bKey).name
      let conversation = try await harness.store.createConversation(
        members: [harness.space.mintPersona(key: aKey).name, bPersona], in: .shared,
      )
      let created = try await harness.post("/v1/tools/table.create", ["path": "/probe.table", "header": ["columns": [["name": "n", "type": "integer"]]]], bearer: b)
      #expect(created.status == .ok)

      let aStreams = try await streams(harness, bearer: a, conversation: conversation)
      let bStreams = try await streams(harness, bearer: b, conversation: conversation)
      #expect(harness.keyStreams.count == 6)

      let revoked = try await harness.api(request("/v1/key", method: .delete, bearer: a))
      #expect(revoked.status == .noContent)
      for reader in aStreams { #expect(await outcome(reader) == .ended) }

      _ = try await harness.space.fs(.shared).write("/probe/still-open.md", Data("x".utf8), ifMatch: nil)
      let inserted = try await harness.post("/v1/tools/table.mutate", ["path": "/probe.table", "ops": [["kind": "insert", "values": [4242]]]], bearer: b)
      #expect(inserted.status == .ok)
      _ = try await harness.store.post(.conversation(conversation), messageID: MessageID("still-open"), sender: Sender(id: bPersona, timeZone: .gmt), content: .init(text: "still-open 4242"))
      for reader in bStreams { #expect(await outcome(reader) == .marked) }

      let reconnect = try await harness.get("/v1/observe", query: ["glob": "/probe/**"], bearer: a)
      #expect(reconnect.status == .unauthorized)
      let refusal = try #require(JSONValue.parse(try await reconnect.text())?.object)
      #expect(refusal["message"]?.stringValue?.contains("revoked") == true)
      #expect(refusal["reason"] == nil)
      #expect(await drained(harness.keyStreams))
    }
  }

  @Test func revokingAnotherKeyOrRemovingTheAccountEndsExactlyItsStreams() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let admin = try await harness.space.addAccount(kind: .human, name: nil, admin: true)
      let (root, _) = try await harness.enrolledBearer(account: admin.id)
      let doomed = try await harness.space.addAccount(kind: .human, name: nil)
      let (first, firstKey) = try await harness.enrolledBearer(account: doomed.id)
      let (second, _) = try await harness.enrolledBearer(account: doomed.id)
      let (other, _) = try await harness.enrolledBearer()
      let firstStream = try await glob(harness, bearer: first)
      let secondStream = try await glob(harness, bearer: second)
      let otherStream = try await glob(harness, bearer: other)

      var revoke = request("/v1/key", method: .delete, bearer: root)
      revoke.body = .bytes(Data(#"{"pubkey":"\#(firstKey.pubkey)"}"#.utf8), contentType: "application/json")
      #expect(try await harness.api(revoke).status == .ok)
      #expect(await outcome(firstStream) == .ended)

      let removal = try await harness.api(request("/v1/accounts/\(doomed.id.rawValue)", method: .delete, bearer: root))
      #expect(removal.status == .ok)
      #expect(await outcome(secondStream) == .ended)

      _ = try await harness.space.fs(.shared).write("/probe/still-open.md", Data("x".utf8), ifMatch: nil)
      #expect(await outcome(otherStream) == .marked)
      #expect(await drained(harness.keyStreams))
    }
  }

  @Test func aSocketEndsOnRevocationAndOneOpenedUnderAGoneKeyEndsAtOnce() async throws {
    try await withDependencies { $0.date = .constant(fixedDate) } operation: {
      let space = try Space.inMemory()
      let account = try await space.addAccount(kind: .human, name: nil)
      let key = try await space.addKey(testPubkey("socket"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let streams = KeyStreams()
      let admitted = await streams.bind(.webSocket { socket in for await _ in socket.inbound {} }, to: key, space: space)
      guard case let .webSocket(session) = admitted else { Issue.record("not a socket"); return }

      let (server, _) = WebSocket.pair()
      let running = Task { await session(server) }
      while streams.count == 0 { await Task.yield() }
      streams.end(pubkey: key.pubkey)
      await running.value
      #expect(streams.count == 0)

      try await space.removeKey(pubkey: key.pubkey)
      let (late, _) = WebSocket.pair()
      await session(late)
      #expect(streams.count == 0)
    }
  }

  @Test func aBufferedResponseIsNotHeld() async throws {
    try await withDependencies { $0.date = .constant(fixedDate) } operation: {
      let space = try Space.inMemory()
      let account = try await space.addAccount(kind: .human, name: nil)
      let key = try await space.addKey(testPubkey("buffered"), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let streams = KeyStreams()
      _ = await streams.bind(.response(Response(status: .ok, body: .string("done"))), to: key, space: space)
      #expect(streams.count == 0)
    }
  }
}

private enum Outcome: Equatable {
  case marked
  case ended
  case stillOpen
}

private let marker = "still-open"

private func request(_ path: String, method: HTTPRequest.Method, bearer: String) -> Request {
  var request = Request(url: URL(string: "http://space" + path)!, method: method)
  request.headers[.authorization] = "Bearer " + bearer
  return request
}

private func streams(_ harness: SessionHarness, bearer: String, conversation: ConversationID) async throws -> [Task<Outcome, Never>] {
  let sql = try await harness.get("/v1/observe", query: ["sql": #"SELECT n FROM "/probe.table""#, "throttleMs": "0"], bearer: bearer)
  let messages = try await harness.get("/v1/conversation/\(conversation.rawValue)/observe", bearer: bearer)
  return try [await glob(harness, bearer: bearer), read(sql, marker: "4242"), read(messages, marker: marker)]
}

private func glob(_ harness: SessionHarness, bearer: String) async throws -> Task<Outcome, Never> {
  try read(await harness.get("/v1/observe", query: ["glob": "/probe/**"], bearer: bearer), marker: marker)
}

// The reader owns the response: once it returns, nothing holds the body, as
// when a connection lets go of it.
private func read(_ response: Response, marker: String) throws -> Task<Outcome, Never> {
  try #require(response.status == .ok)
  return Task {
    var chunks = response.body.asyncBytes().makeAsyncIterator()
    do {
      while let chunk = try await chunks.next() {
        if String(decoding: chunk, as: UTF8.self).contains(marker) { return .marked }
      }
    } catch {}
    return Task.isCancelled ? .stillOpen : .ended
  }
}

private func outcome(_ reader: Task<Outcome, Never>) async -> Outcome {
  await withTaskGroup(of: Outcome?.self) { group in
    group.addTask { await reader.value }
    group.addTask {
      try? await ContinuousClock().sleep(for: bound)
      return nil
    }
    let first = await group.next()!
    reader.cancel()
    group.cancelAll()
    return first ?? .stillOpen
  }
}

private func drained(_ streams: KeyStreams) async -> Bool {
  let deadline = ContinuousClock.now + bound
  while streams.count > 0, ContinuousClock.now < deadline {
    try? await ContinuousClock().sleep(for: .milliseconds(10))
  }
  return streams.count == 0
}
