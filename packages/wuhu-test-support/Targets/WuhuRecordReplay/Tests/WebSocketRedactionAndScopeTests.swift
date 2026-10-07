#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchWebSocket
import Testing
@testable import WuhuRecordReplay

@Suite(.timeLimit(.minutes(1))) struct WebSocketRedactionAndScopeTests {
  private func request() -> WebSocketRequest {
    WebSocketRequest(url: URL(string: "wss://example.test/responses")!)
  }

  private func root() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func unusedFixturesMustFailCompletion() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let redaction = SocketRedaction(request())
    var fixture = SocketFixture(handshake: SocketHandshake(request(), redaction: redaction))
    fixture.journal = [.send(SocketMessage(.text("expected"), redaction: redaction), nil), .end]
    try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("1.websocket.json"))
    let replay = SocketReplay(directory: directory)
    #expect(throws: WebSocketError.self) { try replay.verify() }
  }

  @Test func implicitScopeTeardownMustRoundTrip() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let (stream, events) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    let real = WebSocketConnector { _ in
      WebSocketConnection(inbound: WebSocketInbound(stream), send: { message in
        events.yield(.message(message))
      }, close: { _ in events.finish() }, abort: { events.finish(throwing: WebSocketError.cancelled) })
    }
    let record = RecordingContext(name: "scope", mode: .recordAll, recordingsRoot: root, webSocketConnector: real)
    let socket = try await record.webSocketConnector.connect(request())
    var inbound = socket.inbound.makeAsyncIterator()
    try await socket.send(.text("hello"))
    #expect(try await inbound.next() == .message(.text("hello")))
    await record.finishSockets()
    try await record.flushRecordings()
    let replay = RecordingContext(name: "scope", mode: .replay, recordingsRoot: root)
    let replayed = try await replay.webSocketConnector.connect(request())
    var replayInbound = replayed.inbound.makeAsyncIterator()
    try await replayed.send(.text("hello"))
    #expect(try await replayInbound.next() == .message(.text("hello")))
    await replay.finishSockets()
    try replay.verifyReplay()
  }

  @Test func bareEchoOfCookieCredentialMustBeRedacted() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = WebSocketRequest(url: request().url, headers: RequestHeaders(sensitiveValues: ["cookie": "session=private-cookie-credential"]))
    let recording = SocketRecording()
    let connector = recording.connector(WebSocketConnector { _ in
      throw WebSocketError.refused(status: 401, headers: .init(), body: Array("private-cookie-credential".utf8))
    })
    await #expect(throws: WebSocketError.self) { _ = try await connector.connect(request) }
    try recording.flush(to: directory)
    let fixture = try JSONDecoder().decode(SocketFixture.self, from: Data(contentsOf: directory.appendingPathComponent("1.websocket.json")))
    #expect(!String(decoding: fixture.failure!.body, as: UTF8.self).contains("private-cookie-credential"))
  }

  @Test func bearerDiscoveredInMetadataMustRedactNakedEcho() {
    let redaction = SocketRedaction(request())
    _ = redaction.message("{\"headers\":{\"authorization\":\"Bearer newly-issued-private-token\"}}")
    #expect(!redaction.message("{\"echo\":\"newly-issued-private-token\"}").contains("newly-issued-private-token"))
  }

  @Test func byteRedactionMustTerminate() {
    let request = WebSocketRequest(url: URL(string: "wss://example.test/responses")!, headers: RequestHeaders(sensitiveValues: ["x-secret": "redacted"]))
    let redaction = SocketRedaction(request)
    #expect(redaction.bytes(Array("redacted".utf8)) == Array("<redacted>".utf8))
  }

  @Test func scopeTeardownDoesNotConsumeMissingExplicitAbortOrSend() async throws {
    for action in [SocketAction.abort, .send(SocketMessage(.text("missing"), redaction: SocketRedaction(request())), nil)] {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let redaction = SocketRedaction(request())
      var fixture = SocketFixture(handshake: SocketHandshake(request(), redaction: redaction))
      fixture.journal = [.send(SocketMessage(.text("first"), redaction: redaction), nil), action, .end]
      try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("1.websocket.json"))
      let replay = SocketReplay(directory: directory)
      let socket = try await replay.connector.connect(request())
      try await socket.send(.text("first"))
      replay.finish()
      #expect(throws: WebSocketError.self) { try replay.verify() }
    }
  }

  @Test func redactionScansOriginalBytesOnceForRepeatedAndOverlappingSecrets() {
    let request = WebSocketRequest(url: request().url, headers: RequestHeaders(sensitiveValues: ["x-secret": "redacted", "cookie": "session=long-redacted-value; other=second-private-value"]))
    let redaction = SocketRedaction(request)
    #expect(redaction.text("redacted redacted") == "<redacted> <redacted>")
    #expect(redaction.text("long-redacted-value/second-private-value") == "<redacted>/<redacted>")
    #expect(redaction.bytes([0, 255] + Array("redacted".utf8) + [0]) == [0, 255] + Array("<redacted>".utf8) + [0])
    #expect(redaction.text("<redacted>") == "<redacted>")
  }

  @Test func quotedCookieCredentialMustRedactNakedEcho() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = WebSocketRequest(url: request().url, headers: RequestHeaders(sensitiveValues: ["cookie": "session=\"private-cookie-credential\""]))
    let recording = SocketRecording()
    let connector = recording.connector(WebSocketConnector { _ in
      throw WebSocketError.refused(status: 401, headers: .init(), body: Array("private-cookie-credential".utf8))
    })
    await #expect(throws: WebSocketError.self) { _ = try await connector.connect(request) }
    try recording.flush(to: directory)
    let fixture = try JSONDecoder().decode(SocketFixture.self, from: Data(contentsOf: directory.appendingPathComponent("1.websocket.json")))
    #expect(!String(decoding: fixture.failure!.body, as: UTF8.self).contains("private-cookie-credential"))
  }
}
