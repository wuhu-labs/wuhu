import Fetch
import Synchronization

public enum WebSocketMessage: Sendable, Equatable {
  case binary([UInt8])
  case text(String)
}

public typealias WebSocketSession = @Sendable (WebSocket) async -> Void

public enum UpgradeResult: Sendable {
  case response(Response)
  case webSocket(WebSocketSession)
}

public typealias UpgradingHandler = @Sendable (Request) async throws -> UpgradeResult

public struct WebSocket: Sendable {
  public let inbound: AsyncStream<WebSocketMessage>
  private let sink: @Sendable (WebSocketMessage) async throws -> Void
  private let terminator: @Sendable () -> Void
  private let aborter: @Sendable () -> Void

  public init(
    inbound: AsyncStream<WebSocketMessage>,
    send: @escaping @Sendable (WebSocketMessage) async throws -> Void,
    close: @escaping @Sendable () -> Void,
    abort: @escaping @Sendable () -> Void,
  ) {
    self.inbound = inbound
    sink = send
    terminator = close
    aborter = abort
  }

  public func send(_ message: WebSocketMessage) async throws {
    try await sink(message)
  }

  public func close() {
    terminator()
  }

  public func abort() {
    aborter()
  }
}

extension WebSocket {
  public static func pair() -> (WebSocket, WebSocket) {
    let (aInbound, aContinuation) = AsyncStream<WebSocketMessage>.makeStream()
    let (bInbound, bContinuation) = AsyncStream<WebSocketMessage>.makeStream()
    let closed = Mutex(false)
    let close: @Sendable () -> Void = {
      let wasClosed = closed.withLock { state in
        let was = state
        state = true
        return was
      }
      guard !wasClosed else { return }
      aContinuation.finish()
      bContinuation.finish()
    }
    let send: @Sendable (AsyncStream<WebSocketMessage>.Continuation, WebSocketMessage) throws -> Void = { peer, message in
      guard closed.withLock({ !$0 }) else { throw ServeError.webSocketClosed }
      peer.yield(message)
    }
    return (
      WebSocket(inbound: aInbound, send: { try send(bContinuation, $0) }, close: close, abort: close),
      WebSocket(inbound: bInbound, send: { try send(aContinuation, $0) }, close: close, abort: close),
    )
  }
}

extension Serve {
  public static func isWebSocketUpgradeRequest(_ request: Request) -> Bool {
    guard request.method == .get else { return false }
    let headers = request.headers
    guard let connection = headers["connection"],
          connection.lowercased().split(separator: ",").map(trimmedToken).contains("upgrade"),
          let upgrade = headers["upgrade"], upgrade.lowercased() == "websocket",
          let key = headers["sec-websocket-key"], !key.isEmpty,
          headers["sec-websocket-version"] == "13"
    else { return false }
    return true
  }
}

private func trimmedToken(_ raw: Substring) -> Substring {
  var token = raw
  while token.first?.isWhitespace == true {
    token = token.dropFirst()
  }
  while token.last?.isWhitespace == true {
    token = token.dropLast()
  }
  return token
}
