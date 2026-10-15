import Fetch
import FetchTunnel
import Foundation

public enum TunnelURLSession {
  /// The supplied session owns certificate policy. This adapter never substitutes a session or retries a request.
  public static func connect(url: URL, session: URLSession, headers: RequestHeaders = .init(), limits: BoundedWebSocketLimits = .init()) async throws -> TunnelTransport {
    try limits.validate()
    guard let scheme = url.scheme, ["ws", "wss"].contains(scheme), url.host != nil else { throw TunnelError.invalidConfiguration }
    guard headers["sec-websocket-protocol"] == nil || headers["sec-websocket-protocol"] == TunnelTransport.webSocketSubprotocol else { throw TunnelError.invalidConfiguration }
    var request = URLRequest(url: url)
    for (name, value) in headers.values.merging(headers.sensitiveValues, uniquingKeysWith: { _, last in last }) { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue(TunnelTransport.webSocketSubprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
    let socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = limits.messageBytes
    socket.resume()
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await firstPong { socket.sendPing(pongReceiveHandler: $0) }
        guard (socket.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == TunnelTransport.webSocketSubprotocol else { throw TunnelError.unsupportedSubprotocol }
      } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    }
    let receiver = Receiver(socket: socket, limits: limits)
    return TunnelTransport(maxMessageBytes: limits.messageBytes, receive: { try await receiver.next() }, send: { bytes in
      guard bytes.count <= limits.messageBytes else { throw TunnelError.webSocketLimitExceeded }
      do {
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          try await socket.send(.data(bytes))
          guard (socket.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == TunnelTransport.webSocketSubprotocol else { throw TunnelError.unsupportedSubprotocol }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
      } catch {
        socket.cancel(with: .goingAway, reason: nil)
        throw error
      }
    }, abort: { socket.cancel(with: .goingAway, reason: nil) })
  }
}

/// Sends one transport ping through `sendPing` and returns when its first outcome arrives.
///
/// URLSession can call one pong handler twice: cancelling the task while the ping is pending calls it with
/// ECONNABORTED, and a connection reset during the teardown calls it again. The handler feeds a stream, and only the
/// first outcome is read. Cancelling the waiting task throws CancellationError without waiting for an outcome.
func firstPong(_ sendPing: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
  let outcomes = AsyncThrowingStream<Void, any Error> { continuation in
    sendPing { error in
      if let error { continuation.finish(throwing: error) } else { continuation.yield(); continuation.finish() }
    }
  }
  for try await _ in outcomes { return }
  throw CancellationError()
}

private actor Receiver {
  let socket: URLSessionWebSocketTask
  let limits: BoundedWebSocketLimits
  var advancing = false
  init(socket: URLSessionWebSocketTask, limits: BoundedWebSocketLimits) { self.socket = socket; self.limits = limits }
  func next() async throws -> Bytes? {
    guard !advancing else { throw TunnelError.protocolViolation }
    advancing = true
    defer { advancing = false }
    do {
      let message = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await socket.receive()
      } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
      guard (socket.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == TunnelTransport.webSocketSubprotocol else { throw TunnelError.unsupportedSubprotocol }
      guard case .data(let bytes) = message else { throw TunnelError.protocolViolation }
      guard bytes.count <= limits.messageBytes else { throw TunnelError.webSocketLimitExceeded }
      return bytes
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    }
  }
}
