#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import Dependencies
import Fetch
import FetchWebSocket
import Synchronization
import Testing
@testable import WuhuRecordReplay

@Suite(.serialized, .timeLimit(.minutes(1))) struct WebSocketReplayBoundaryTests {
  private func request() -> WebSocketRequest { .init(url: URL(string: "wss://example.test/responses")!) }
  private func fixture(_ journal: [SocketAction]) -> SocketFixture {
    var fixture = SocketFixture(handshake: SocketHandshake(request(), redaction: SocketRedaction(request())))
    fixture.journal = journal
    return fixture
  }

  private func send(_ text: String) -> SocketAction { .send(SocketMessage(.text(text), redaction: SocketRedaction(request())), nil) }
  private func receive(_ text: String) -> SocketAction { .receive(SocketMessage(.text(text), redaction: SocketRedaction(request()))) }
  private func directory(_ fixtures: [SocketFixture]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, fixture) in fixtures.enumerated() { try JSONEncoder().encode(fixture).write(to: root.appendingPathComponent("\(index + 1).websocket.json")) }
    return root
  }

  @Test(arguments: ["function_call_output", "", "unknown"])
  func reconnectReferencesCannotFreeBindAndLiteralReferencesRemainValid(type: String) async throws {
    let first = fixture([send("first"), receive(#"{"response":{"id":"resp_a"},"call_id":"call_a"}"#), .end])
    let typeField = type.isEmpty ? "" : "\"type\":\"\(type)\","
    let continuation = "{\"type\":\"response.create\",\"previous_response_id\":\"resp_a\",\"input\":[{\(typeField)\"call_id\":\"call_a\",\"output\":\"ok\"}]}"
    let second = fixture([send(continuation), .end])
    for actual in [continuation, continuation.replacingOccurrences(of: "resp_a", with: "resp_TYPO"), continuation.replacingOccurrences(of: "call_a", with: "call_TYPO")] {
      let root = try directory([first, second])
      defer { try? FileManager.default.removeItem(at: root) }
      let replay = SocketReplay(directory: root)
      let a = try await replay.connector.connect(request())
      try await a.send(.text("first"))
      let b = try await replay.connector.connect(request())
      if actual == continuation { try await b.send(.text(actual)); try replay.verify() }
      else {
        await #expect(throws: WebSocketError.self) { try await b.send(.text(actual)) }
        #expect(throws: WebSocketError.self) { try replay.verify() }
      }
    }
  }

  @Test func referencesUseAliasesOnlyAfterFullRequestEstablishment() {
    var ids = SocketIDMap()
    let matched1 = ids.matches(.text(#"{"input":[{"type":"function_call","id":"fc_a","call_id":"call_a","arguments":"{}"},{"type":"function_call_output","call_id":"call_a","output":"ok"}]}"#), .text(#"{"input":[{"type":"function_call","id":"fc_dynamic","call_id":"call_dynamic","arguments":"{}"},{"type":"function_call_output","call_id":"call_dynamic","output":"ok"}]}"#))
    #expect(matched1)
    let matched2 = ids.matches(.text(#"{"item_id":"fc_a"}"#), .text(#"{"item_id":"fc_dynamic"}"#))
    #expect(matched2)
    let matched3 = !ids.matches(.text(#"{"item_id":"fc_unseen"}"#), .text(#"{"item_id":"fc_typo"}"#))
    #expect(matched3)
    let matched4 = !ids.matches(.text(#"{"type":"function_call_output","call_id":"call_unseen"}"#), .text(#"{"type":"function_call_output","call_id":"call_typo"}"#))
    #expect(matched4)
  }

  @Test func arrayReferencesCannotIntroduceAliases() {
    var ids = SocketIDMap()
    let matchedArray1 = !ids.matches(.text(#"{"call_id":["call_a"]}"#), .text(#"{"call_id":["call_TYPO"]}"#))
    #expect(matchedArray1)
    let matchedArray2 = !ids.matches(.text(#"{"input":[{"call_id":"call_a","output":"ok"}]}"#), .text(#"{"input":[{"call_id":"call_TYPO","output":"ok"}]}"#))
    #expect(matchedArray2)
    let matchedArray3 = ids.matches(.text(#"{"input":[{"type":"function_call","call_id":"call_a"}]}"#), .text(#"{"input":[{"type":"function_call","call_id":"call_dynamic"}]}"#))
    #expect(matchedArray3)
    let matchedArray4 = ids.matches(.text(#"{"call_id":["call_a"]}"#), .text(#"{"call_id":["call_dynamic"]}"#))
    #expect(matchedArray4)
  }

  @Test(arguments: ["dial-outcomes", "upgrade-headers", "pre-send", "no-match"])
  func ambiguousOrUnmatchedHandshakeFailsClosed(_ kind: String) async throws {
    var first = fixture([send("one"), .end])
    var second = fixture([send("two"), .end])
    if kind == "dial-outcomes" { first.failure = SocketFailure(WebSocketError.connectTimeout, redaction: SocketRedaction(request())) }
    if kind == "upgrade-headers" { second.responseHeaders = ["retry-after": "1"] }
    if kind == "pre-send" { first.journal.insert(receive("early"), at: 0) }
    let root = try directory([first, second])
    defer { try? FileManager.default.removeItem(at: root) }
    let replay = SocketReplay(directory: root)
    var request = request()
    if kind == "no-match" { request.url = URL(string: "wss://different.test/")! }
    await #expect(throws: WebSocketError.self) { _ = try await replay.connector.connect(request) }
  }

  @Test(arguments: ["order", "opcode", "close-code", "close-reason", "missing-send"])
  func incorrectClientActionsRemainUnconsumed(_ kind: String) async throws {
    let expectedClose = SocketClose(.init(code: 1001, reason: "bye"), redaction: SocketRedaction(request()))
    let root = try directory([fixture([send("one"), send("two"), .close(expectedClose, nil), .end])])
    defer { try? FileManager.default.removeItem(at: root) }
    let replay = SocketReplay(directory: root)
    let socket = try await replay.connector.connect(request())
    if kind == "order" { await #expect(throws: WebSocketError.self) { try await socket.send(.text("two")) } }
    else if kind == "opcode" { await #expect(throws: WebSocketError.self) { try await socket.send(.binary(Array("one".utf8))) } }
    else {
      try await socket.send(.text("one"))
      if kind != "missing-send" {
        try await socket.send(.text("two"))
        await #expect(throws: WebSocketError.self) { try await socket.close(.init(code: kind == "close-code" ? 1000 : 1001, reason: kind == "close-reason" ? "wrong" : "bye")) }
      }
    }
    replay.finish()
    #expect(throws: WebSocketError.self) { try replay.verify() }
  }

  @Test func explicitAbortRoundTripsAndUnusedFixturesFail() async throws {
    let root = try directory([fixture([send("one"), .abort, .receiveFailure(SocketFailure(WebSocketError.cancelled, redaction: SocketRedaction(request())))])])
    defer { try? FileManager.default.removeItem(at: root) }
    let replay = SocketReplay(directory: root)
    #expect(throws: WebSocketError.self) { try replay.verify() }
    let socket = try await replay.connector.connect(request())
    try await socket.send(.text("one"))
    socket.abort()
    var iterator = socket.inbound.makeAsyncIterator()
    await #expect(throws: WebSocketError.cancelled) { _ = try await iterator.next() }
    replay.finish()
    try replay.verify()
  }

  @Test func publicScopeInjectsTeardownPersistsVerifiesAndNeverFlushesFailure() async throws {
    let root = try directory([])
    defer { try? FileManager.default.removeItem(at: root) }
    let name = "websocket-public-\(UUID().uuidString)"
    let environment = ProcessInfo.processInfo.environment
    let file = root.appendingPathComponent("probe.swift").path
    defer {
      if let value = environment["RECORDING"] { setenv("RECORDING", value, 1) } else { unsetenv("RECORDING") }
      if let value = environment["RECORDINGS_ROOT"] { setenv("RECORDINGS_ROOT", value, 1) } else { unsetenv("RECORDINGS_ROOT") }
    }
    setenv("RECORDING", name, 1)
    setenv("RECORDINGS_ROOT", root.appendingPathComponent("Recordings").path, 1)
    let calls = Mutex(0)
    let fake = WebSocketConnector { _ in
      calls.withLock { $0 += 1 }
      let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
      return WebSocketConnection(inbound: .init(events.stream), send: { events.continuation.yield(.message($0)) }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish(throwing: WebSocketError.cancelled) })
    }
    let held = Mutex<WebSocketConnection?>(nil)
    let exercise: @Sendable () async throws -> Void = {
      @Dependency(WebSocketConnector.self) var connector
      let socket = try await connector.connect(request())
      held.withLock { $0 = socket }
      var inbound = socket.inbound.makeAsyncIterator()
      try await socket.send(.text("echo"))
      #expect(try await inbound.next() == .message(.text("echo")))
    }
    try await withDependencies { $0[WebSocketConnector.self] = fake } operation: {
      try await withRecording(name, file: file, body: exercise)
    }
    let fixturePath = root.appendingPathComponent("Recordings/\(name)/1.websocket.json")
    let recorded = try Data(contentsOf: fixturePath)
    let fixture = try JSONDecoder().decode(SocketFixture.self, from: recorded)
    #expect(fixture.journal.contains { if case .scopeAbort = $0 { true } else { false } })
    setenv("RECORDING", "", 1)
    try await withDependencies { $0[WebSocketConnector.self] = fake } operation: {
      try await withRecording(name, file: file, body: exercise)
      await #expect(throws: WebSocketError.self) { try await withRecording(name, file: file) {} }
    }
    #expect(calls.withLock { $0 } == 1)
    setenv("RECORDING", name, 1)
    await withDependencies { $0[WebSocketConnector.self] = fake } operation: {
      await #expect(throws: ScopeFailure.self) {
        try await withRecording(name, file: file) { try await exercise(); throw ScopeFailure() }
      }
    }
    #expect(try Data(contentsOf: fixturePath) == recorded)
  }
}

private struct ScopeFailure: Error {}
