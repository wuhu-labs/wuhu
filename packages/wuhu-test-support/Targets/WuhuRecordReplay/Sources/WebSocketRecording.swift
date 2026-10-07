#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FetchWebSocket
import Synchronization

final class SocketRecording: Sendable {
  private let fixtures = Mutex<[SocketFixture]>([])
  private let cleanup = Mutex<[@Sendable () async -> Void]>([])

  func connector(_ real: WebSocketConnector) -> WebSocketConnector {
    WebSocketConnector { request in
      guard request.url.user == nil, request.url.password == nil else { throw WebSocketError.invalidConfiguration("Recording URL credentials is unsupported") }
      if case .configuration = request.tls { throw WebSocketError.invalidConfiguration("Recording custom TLS configurations is unsupported") }
      let redaction = SocketRedaction(request)
      let index = self.fixtures.withLock { fixtures in
        fixtures.append(SocketFixture(handshake: SocketHandshake(request, redaction: redaction)))
        return fixtures.count - 1
      }
      let connection: WebSocketConnection
      do { connection = try await real.connect(request) }
      catch {
        self.fixtures.withLock { $0[index].failure = SocketFailure(error, redaction: redaction) }
        throw error
      }
      self.fixtures.withLock { $0[index].responseHeaders = redaction.headers(connection.responseHeaders) }
      let (stream, continuation) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
      let pump = Task {
        do {
          for try await event in connection.inbound {
            switch event {
            case .message(let message): self.append(.receive(SocketMessage(message, redaction: redaction)), at: index)
            case .closed(let close): self.append(.receivedClose(SocketClose(close, redaction: redaction)), at: index)
            }
            continuation.yield(event)
          }
          self.append(.end, at: index)
          continuation.finish()
        } catch {
          self.append(.receiveFailure(SocketFailure(error, redaction: redaction)), at: index)
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in pump.cancel(); connection.abort() }
      self.cleanup.withLock { cleanups in
        cleanups.append { [weak self] in
          guard let self else { connection.abort(); pump.cancel(); await pump.value; return }
          let needsAbort = self.fixtures.withLock { fixtures in
            !fixtures[index].journal.contains { action in
              switch action {
              case .close, .abort, .scopeAbort, .receivedClose, .receiveFailure, .end: true
              default: false
              }
            }
          }
          if needsAbort { self.append(.scopeAbort, at: index) }
          connection.abort()
          pump.cancel()
          await pump.value
        }
      }
      return WebSocketConnection(
        responseHeaders: connection.responseHeaders,
        inbound: WebSocketInbound(stream),
        send: { message in
          let position = self.append(.send(SocketMessage(message, redaction: redaction), nil), at: index)
          do { try await connection.send(message) }
          catch {
            self.replace(.send(SocketMessage(message, redaction: redaction), SocketFailure(error, redaction: redaction)), at: index, position: position)
            throw error
          }
        },
        close: { close in
          let position = self.append(.close(SocketClose(close, redaction: redaction), nil), at: index)
          do { try await connection.close(close) }
          catch {
            self.replace(.close(SocketClose(close, redaction: redaction), SocketFailure(error, redaction: redaction)), at: index, position: position)
            throw error
          }
        },
        abort: {
          self.append(.abort, at: index)
          connection.abort()
          pump.cancel()
        },
      )
    }
  }

  @discardableResult
  private func append(_ action: SocketAction, at index: Int) -> Int {
    fixtures.withLock {
      $0[index].journal.append(action)
      return $0[index].journal.count - 1
    }
  }

  private func replace(_ action: SocketAction, at index: Int, position: Int) {
    fixtures.withLock { $0[index].journal[position] = action }
  }

  func finish() async {
    let cleanups = cleanup.withLock { cleanups in
      defer { cleanups.removeAll() }
      return cleanups
    }
    for cleanup in cleanups { await cleanup() }
  }

  func flush(to directory: URL) throws {
    let snapshot = fixtures.withLock { $0 }
    guard !snapshot.isEmpty else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (index, fixture) in snapshot.enumerated() {
      try encoder.encode(fixture).write(to: directory.appendingPathComponent("\(index + 1).websocket.json"))
    }
  }
}
