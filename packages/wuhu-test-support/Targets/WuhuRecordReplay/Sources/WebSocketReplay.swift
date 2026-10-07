#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchWebSocket
import Synchronization

final class SocketReplay: Sendable {
  private struct State: Sendable {
    var fixtures: [SocketFixture]?
    var claimed: Set<Int> = []
    var positions: [Int: Int] = [:]
  }

  private let state = Mutex(State())
  private let directory: URL
  private let sockets = Mutex<[ReplayedSocket]>([])

  init(directory: URL) { self.directory = directory }

  var connector: WebSocketConnector {
    WebSocketConnector { request in try self.connect(request) }
  }

  private func connect(_ request: WebSocketRequest) throws -> WebSocketConnection {
    guard request.url.user == nil, request.url.password == nil else { throw WebSocketError.invalidConfiguration("Recording URL credentials is unsupported") }
    if case .configuration = request.tls { throw WebSocketError.invalidConfiguration("Recording custom TLS configurations is unsupported") }
    let redaction = SocketRedaction(request)
    let handshake = SocketHandshake(request, redaction: redaction)
    let (candidates, preclaimed) = try state.withLock { state -> ([SocketFixture], (Int, SocketFixture)?) in
      try load(&state)
      let candidates = state.fixtures!.enumerated().filter { !state.claimed.contains($0.offset) && $0.element.handshake == handshake }
      guard !candidates.isEmpty else { throw WebSocketError.invalidConfiguration("No unclaimed WebSocket recording matches the handshake") }
      if let failed = candidates.first(where: { $0.element.failure != nil }) {
        guard candidates.allSatisfy({ $0.element.failure == failed.element.failure }) else {
          throw WebSocketError.invalidConfiguration("Ambiguous recorded dial outcomes before first send")
        }
        state.claimed.insert(failed.offset)
        throw failed.element.failure!.error
      }
      let fixtures = candidates.map(\.element)
      guard fixtures.allSatisfy({ $0.responseHeaders == fixtures[0].responseHeaders }) else {
        throw WebSocketError.invalidConfiguration("Ambiguous recorded upgrade headers before first send")
      }
      let hasEarlyReceive = fixtures.contains { fixture in
        guard let first = fixture.journal.first else { return true }
        switch first { case .send, .close, .abort, .scopeAbort: return false; default: return true }
      }
      if hasEarlyReceive {
        guard candidates.count == 1 else { throw WebSocketError.invalidConfiguration("Ambiguous pre-send WebSocket events") }
        state.claimed.insert(candidates[0].offset)
        return (fixtures, (candidates[0].offset, candidates[0].element))
      }
      return (fixtures, nil)
    }
    let socket = ReplayedSocket(ledger: self, handshake: handshake, redaction: redaction, preclaimed: preclaimed)
    sockets.withLock { $0.append(socket) }
    return WebSocketConnection(
      responseHeaders: RequestHeaders(values: candidates[0].responseHeaders).fields,
      inbound: WebSocketInbound(socket.stream),
      send: { [self] message in try withExtendedLifetime(self) { try socket.send(message) } },
      close: { [self] close in try withExtendedLifetime(self) { try socket.close(close) } },
      abort: { [self] in withExtendedLifetime(self) { socket.abort() } },
    )
  }

  func verify() throws {
    try state.withLock { state in
      try load(&state)
      let fixtures = state.fixtures!
      guard state.claimed.count == fixtures.count else { throw WebSocketError.protocolViolation("Unclaimed WebSocket fixtures") }
      for (index, position) in state.positions where position != fixtures[index].journal.count {
        throw WebSocketError.protocolViolation("Unconsumed WebSocket journal entries")
      }
    }
  }

  private func load(_ state: inout State) throws {
    guard state.fixtures == nil else { return }
    let files = FileManager.default.fileExists(atPath: directory.path)
      ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
    state.fixtures = try files.filter { $0.lastPathComponent.hasSuffix(".websocket.json") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { try JSONDecoder().decode(SocketFixture.self, from: Data(contentsOf: $0)) }
  }

  func finish() {
    let owned = sockets.withLock { sockets in
      defer { sockets.removeAll() }
      return sockets
    }
    for socket in owned { socket.finishScope() }
  }

  fileprivate func consumed(index: Int, position: Int) {
    state.withLock { $0.positions[index] = position }
  }

  fileprivate func claim(handshake: SocketHandshake, first action: SocketAction, ids: inout SocketIDMap) throws -> (Int, SocketFixture) {
    try state.withLock { state in
      for (index, fixture) in (state.fixtures ?? []).enumerated() where !state.claimed.contains(index) && fixture.handshake == handshake {
        guard let expected = fixture.journal.first else { continue }
        var candidate = ids
        guard socketActionMatches(expected, action, ids: &candidate) else { continue }
        state.claimed.insert(index)
        ids = candidate
        return (index, fixture)
      }
      throw WebSocketError.protocolViolation("No WebSocket recording matches the first client action")
    }
  }
}

private final class ReplayedSocket: Sendable {
  struct State: Sendable {
    var fixture: SocketFixture?
    var position = 0
    var index: Int?
    var ids = SocketIDMap()
    var terminated = false
  }

  let stream: AsyncThrowingStream<WebSocketEvent, any Error>
  private let continuation: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation
  private let state = Mutex(State())
  private weak let ledger: SocketReplay?
  private let handshake: SocketHandshake
  private let redaction: SocketRedaction

  init(ledger: SocketReplay, handshake: SocketHandshake, redaction: SocketRedaction, preclaimed: (Int, SocketFixture)?) {
    self.ledger = ledger
    self.handshake = handshake
    self.redaction = redaction
    (stream, continuation) = AsyncThrowingStream.makeStream()
    if let (index, fixture) = preclaimed {
      state.withLock { state in
        state.index = index
        state.fixture = fixture
        releaseReceives(&state)
        ledger.consumed(index: index, position: state.position)
      }
    }
  }

  func send(_ message: WebSocketMessage) throws {
    try advance(.send(SocketMessage(message, redaction: redaction), nil))
  }

  func close(_ close: WebSocketClose) throws {
    try advance(.close(SocketClose(close, redaction: redaction), nil))
  }

  func abort() {
    do { try advance(.abort) }
    catch { continuation.finish(throwing: error) }
  }

  func finishScope() {
    let needsAbort = state.withLock { state in
      guard !state.terminated else { return false }
      guard let fixture = state.fixture else { return true }
      guard state.position < fixture.journal.count else { return false }
      if case .scopeAbort = fixture.journal[state.position] { return true }
      return false
    }
    if needsAbort {
      do { try advance(.scopeAbort) }
      catch { continuation.finish(throwing: error) }
    }
    continuation.finish(throwing: WebSocketError.cancelled)
  }

  private func advance(_ action: SocketAction) throws {
    do {
      try state.withLock { state in
        guard !state.terminated else { throw WebSocketError.connectionClosed }
        if state.fixture == nil {
          guard let ledger else { throw WebSocketError.connectionClosed }
          let (index, fixture) = try ledger.claim(handshake: handshake, first: action, ids: &state.ids)
          state.index = index
          state.fixture = fixture
        }
        let fixture = state.fixture!
        guard state.position < fixture.journal.count,
              socketActionMatches(fixture.journal[state.position], action, ids: &state.ids)
        else { throw WebSocketError.protocolViolation("WebSocket replay client action mismatch at journal entry \(state.position)") }
        let expected = fixture.journal[state.position]
        state.position += 1
        releaseReceives(&state)
        ledger?.consumed(index: state.index!, position: state.position)
        switch expected {
        case .send(_, let failure), .close(_, let failure): if let failure { throw failure.error }
        case .abort, .scopeAbort: state.terminated = true; continuation.finish(throwing: WebSocketError.cancelled)
        default: break
        }
      }
    } catch {
      continuation.finish(throwing: error)
      throw error
    }
  }

  private func releaseReceives(_ state: inout State) {
    guard let fixture = state.fixture else { return }
    while state.position < fixture.journal.count {
      switch fixture.journal[state.position] {
      case .receive(let message): continuation.yield(.message(state.ids.received(message.message)))
      case .receivedClose(let close): continuation.yield(.closed(close.close))
      case .receiveFailure(let failure): continuation.finish(throwing: failure.error)
      case .end: continuation.finish()
      default: return
      }
      state.position += 1
    }
  }
}

private func socketActionMatches(_ expected: SocketAction, _ actual: SocketAction, ids: inout SocketIDMap) -> Bool {
  switch (expected, actual) {
  case (.send(let l, _), .send(let r, _)): ids.matches(l.message, r.message)
  case (.close(let l, _), .close(let r, _)): l.code == r.code && l.reason == r.reason
  case (.abort, .abort), (.scopeAbort, .scopeAbort): true
  default: false
  }
}
