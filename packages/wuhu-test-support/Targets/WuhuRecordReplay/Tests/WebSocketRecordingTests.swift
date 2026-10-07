#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchWebSocket
import JSONValue
import Testing
@testable import WuhuRecordReplay

struct WebSocketRecordingTests {
  private func request() -> WebSocketRequest {
    WebSocketRequest(url: URL(string: "wss://example.test/responses")!, headers: RequestHeaders(
      values: ["originator": "test"], sensitiveValues: ["authorization": "Bearer private-token", "chatgpt-account-id": "private-account"],
    ))
  }

  private func fixture(_ first: String, response: String = "resp_a", call: String = "call_a") -> SocketFixture {
    let redaction = SocketRedaction(request())
    var fixture = SocketFixture(handshake: SocketHandshake(request(), redaction: redaction))
    fixture.journal = [
      .send(SocketMessage(.text(first), redaction: redaction), nil),
      .receive(SocketMessage(.text("{\"type\":\"response.completed\",\"response\":{\"id\":\"\(response)\"},\"call_id\":\"\(call)\"}"), redaction: redaction)),
      .send(SocketMessage(.text("{\"type\":\"response.create\",\"previous_response_id\":\"\(response)\",\"input\":[{\"call_id\":\"\(call)\",\"output\":\"ok\"}]}"), redaction: redaction), nil),
      .receive(SocketMessage(.binary([1, 2]), redaction: redaction)),
      .close(SocketClose(.init(code: 1001, reason: "finished"), redaction: redaction), nil),
      .receivedClose(SocketClose(.init(code: 1001, reason: "finished"), redaction: redaction)),
      .end,
    ]
    return fixture
  }

  private func directory(_ fixtures: [SocketFixture]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (index, fixture) in fixtures.enumerated() {
      try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("\(index + 1).websocket.json"))
    }
    return directory
  }

  @Test func causalTwoTurnReplayAndClose() async throws {
    let first = "{\"type\":\"response.create\",\"input\":[\"hello\"]}"
    let directory = try directory([fixture(first)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = try await SocketReplay(directory: directory).connector.connect(request())
    var iterator = socket.inbound.makeAsyncIterator()
    try await socket.send(.text(first))
    #expect(try await iterator.next() != nil)
    try await socket.send(.text("{\"input\":[{\"output\":\"ok\",\"call_id\":\"call_a\"}],\"previous_response_id\":\"resp_a\",\"type\":\"response.create\"}"))
    #expect(try await iterator.next() == .message(.binary([1, 2])))
    try await socket.close(.init(code: 1001, reason: "finished"))
    #expect(try await iterator.next() == .closed(.init(code: 1001, reason: "finished")))
    #expect(try await iterator.next() == nil)
  }

  @Test func reversedIndependentSocketArrivalClaimsByCreate() async throws {
    let first = "{\"type\":\"response.create\",\"input\":[\"first\"]}"
    let second = "{\"type\":\"response.create\",\"input\":[\"second\"]}"
    let directory = try directory([fixture(first), fixture(second, response: "resp_b", call: "call_b")])
    defer { try? FileManager.default.removeItem(at: directory) }
    let replay = SocketReplay(directory: directory)
    let b = try await replay.connector.connect(request())
    let a = try await replay.connector.connect(request())
    try await b.send(.text(second))
    try await a.send(.text(first))
    var bEvents = b.inbound.makeAsyncIterator(), aEvents = a.inbound.makeAsyncIterator()
    guard case .message(.text(let bText)) = try await bEvents.next(),
          case .message(.text(let aText)) = try await aEvents.next() else { Issue.record("missing response"); return }
    #expect(bText.contains("resp_b"))
    #expect(aText.contains("resp_a"))
  }

  @Test(arguments: ["wrong-response", "wrong-call"])
  func referencesAreNeverIgnored(_ wrong: String) async throws {
    let first = "{\"type\":\"response.create\",\"input\":[]}"
    let directory = try directory([fixture(first)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = try await SocketReplay(directory: directory).connector.connect(request())
    try await socket.send(.text(first))
    let response = wrong == "wrong-response" ? "resp_wrong" : "resp_a"
    let call = wrong == "wrong-call" ? "call_wrong" : "call_a"
    await #expect(throws: WebSocketError.self) {
      try await socket.send(.text("{\"type\":\"response.create\",\"previous_response_id\":\"\(response)\",\"input\":[{\"call_id\":\"\(call)\",\"output\":\"ok\"}]}"))
    }
  }

  @Test func bijectiveIDsAndExactArgumentStrings() {
    var ids = SocketIDMap()
    let matched1 = ids.matches(.text("{\"input\":[{\"type\":\"function_call\",\"call_id\":\"call_a\"},{\"type\":\"function_call\",\"call_id\":\"call_b\"}]}"), .text("{\"input\":[{\"type\":\"function_call\",\"call_id\":\"kernel_a\"},{\"type\":\"function_call\",\"call_id\":\"kernel_b\"}]}"))
    #expect(matched1)
    let matched2 = !ids.matches(.text("{\"call_id\":\"call_a\"}"), .text("{\"call_id\":\"kernel_b\"}"))
    #expect(matched2)
    let matched3 = !ids.matches(.text("{\"arguments\":\"{ \\\"n\\\": 1 }\"}"), .text("{\"arguments\":\"{\\\"n\\\":1}\"}"))
    #expect(matched3)
    #expect(ids.received(.text("{\"call_id\":\"call_a\"}")) == .text("{\"call_id\":\"kernel_a\"}"))
  }

  @Test func recordingRedactsRefusalAndReplaysTypedFailure() async throws {
    let directory = try directory([])
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = SocketRecording()
    let connector = recording.connector(WebSocketConnector { _ in
      throw WebSocketError.refused(
        status: 429,
        headers: RequestHeaders(values: ["retry-after": "5", "set-cookie": "private-cookie"]).fields,
        body: Array("private-token private-account".utf8),
      )
    })
    await #expect(throws: WebSocketError.self) { _ = try await connector.connect(request()) }
    try recording.flush(to: directory)
    let bytes = try Data(contentsOf: directory.appendingPathComponent("1.websocket.json"))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("private-token"))
    #expect(!text.contains("private-account"))
    #expect(!text.contains("private-cookie"))
    do { _ = try await SocketReplay(directory: directory).connector.connect(request()); Issue.record("expected refusal") }
    catch let error as WebSocketError {
      guard case .refused(let status, let headers, let body) = error else { Issue.record("wrong error"); return }
      #expect(status == 429)
      #expect(headers[.retryAfter] == "5")
      #expect(String(decoding: body, as: UTF8.self) == "<redacted> <redacted>")
    }
  }

  @Test func recordedTwoWayJournalRoundTrips() async throws {
    let directory = try directory([])
    defer { try? FileManager.default.removeItem(at: directory) }
    let (server, events) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    let live = WebSocketConnector { _ in
      WebSocketConnection(inbound: WebSocketInbound(server), send: { message in
        events.yield(.message(message))
      }, close: { close in
        events.yield(.closed(close)); events.finish()
      }, abort: { events.finish(throwing: WebSocketError.cancelled) })
    }
    let recording = SocketRecording()
    let socket = try await recording.connector(live).connect(request())
    var iterator = socket.inbound.makeAsyncIterator()
    try await socket.send(.text("one"))
    #expect(try await iterator.next() == .message(.text("one")))
    try await socket.send(.binary([3, 4]))
    #expect(try await iterator.next() == .message(.binary([3, 4])))
    try await socket.close(.init())
    #expect(try await iterator.next() == .closed(.init()))
    #expect(try await iterator.next() == nil)
    await recording.finish()
    try recording.flush(to: directory)
    let replay = SocketReplay(directory: directory)
    let replayed = try await replay.connector.connect(request())
    var replayEvents = replayed.inbound.makeAsyncIterator()
    try await replayed.send(.text("one"))
    #expect(try await replayEvents.next() == .message(.text("one")))
    try await replayed.send(.binary([3, 4]))
    #expect(try await replayEvents.next() == .message(.binary([3, 4])))
    try await replayed.close()
    #expect(try await replayEvents.next() == .closed(.init()))
    #expect(try await replayEvents.next() == nil)
    try replay.verify()
  }

  @Test func receiveFailureAndFailedSendRemainTyped() async throws {
    let redaction = SocketRedaction(request())
    var fixture = SocketFixture(handshake: SocketHandshake(request(), redaction: redaction))
    fixture.journal = [
      .send(SocketMessage(.text("bad"), redaction: redaction), SocketFailure(WebSocketError.limitExceeded(.outboundMessage), redaction: redaction)),
      .receiveFailure(SocketFailure(WebSocketError.protocolViolation("invalid UTF-8"), redaction: redaction)),
    ]
    let directory = try directory([fixture])
    defer { try? FileManager.default.removeItem(at: directory) }
    let replay = SocketReplay(directory: directory)
    let socket = try await replay.connector.connect(request())
    await #expect(throws: WebSocketError.limitExceeded(.outboundMessage)) { try await socket.send(.text("bad")) }
    var iterator = socket.inbound.makeAsyncIterator()
    await #expect(throws: WebSocketError.protocolViolation("invalid UTF-8")) { _ = try await iterator.next() }
    try replay.verify()
  }

  @Test func reconnectCannotBorrowPriorConnectionAliases() {
    var first = SocketIDMap(), second = SocketIDMap()
    let renamed = first.matches(.text("{\"type\":\"function_call\",\"call_id\":\"call_a\"}"), .text("{\"type\":\"function_call\",\"call_id\":\"kernel_a\"}"))
    #expect(renamed)
    _ = second.received(.text("{\"call_id\":\"call_a\"}"))
    let borrowed = second.matches(.text("{\"call_id\":\"call_a\"}"), .text("{\"call_id\":\"kernel_a\"}"))
    #expect(!borrowed)
  }

  @Test func metadataAndEchoedRoutingSecretsAreRedacted() {
    let redaction = SocketRedaction(request())
    let metadata = redaction.message("{\"type\":\"codex.response.metadata\",\"headers\":{\"x-routing-token\":\"private-routing\"},\"authorization\":\"Bearer private-token\"}")
    #expect(!metadata.contains("private-routing"))
    #expect(!metadata.contains("private-token"))
    #expect(redaction.message("{\"echo\":\"private-routing\"}") == "{\"echo\":\"<redacted>\"}")
  }

  @Test func earlyReceiveErrorDoesNotWaitForClientSend() async throws {
    let redaction = SocketRedaction(request())
    var fixture = SocketFixture(handshake: SocketHandshake(request(), redaction: redaction))
    fixture.journal = [.receiveFailure(SocketFailure(WebSocketError.connectionClosed, redaction: redaction))]
    let directory = try directory([fixture])
    defer { try? FileManager.default.removeItem(at: directory) }
    let replay = SocketReplay(directory: directory)
    let socket = try await replay.connector.connect(request())
    var iterator = socket.inbound.makeAsyncIterator()
    await #expect(throws: WebSocketError.connectionClosed) { _ = try await iterator.next() }
    try replay.verify()
  }

  @Test func projectedServerIDsCannotCollideWithRenamedClientIDs() {
    var ids = SocketIDMap()
    let matches = ids.matches(.text("{\"type\":\"function_call\",\"call_id\":\"call_a\"}"), .text("{\"type\":\"function_call\",\"call_id\":\"call_b\"}"))
    #expect(matches)
    let projected = ids.received(.text("{\"call_id\":\"call_b\"}"))
    #expect(projected == .text("{\"call_id\":\"call_b__replay_1\"}"))
    let collapses = ids.matches(.text("{\"call_id\":\"call_b\"}"), .text("{\"call_id\":\"call_b\"}"))
    #expect(!collapses)
  }
}
