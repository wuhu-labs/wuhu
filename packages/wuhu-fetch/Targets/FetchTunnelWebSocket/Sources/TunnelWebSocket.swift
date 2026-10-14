import Fetch
import FetchTunnel
import FetchWebSocket

public enum TunnelWebSocket {
  public static func connect(_ request: WebSocketRequest, connector: WebSocketConnector = .live) async throws -> TunnelTransport {
    guard request.headers["sec-websocket-protocol"] == nil || request.headers["sec-websocket-protocol"] == TunnelTransport.webSocketSubprotocol else { throw TunnelError.invalidConfiguration }
    var request = request
    request.headers["sec-websocket-protocol"] = TunnelTransport.webSocketSubprotocol
    let connection = try await connector.connect(request)
    guard connection.responseHeaders[.init("sec-websocket-protocol")!] == TunnelTransport.webSocketSubprotocol else {
      connection.abort()
      throw TunnelError.unsupportedSubprotocol
    }
    let receiver = Receiver(connection.inbound)
    return TunnelTransport(maxMessageBytes: min(request.limits.frameBytes, request.limits.messageBytes, request.limits.outboundMessageBytes), receive: { try await receiver.next() }, send: { try await connection.send(.binary(Array($0))) }, abort: connection.abort)
  }
}

private actor Receiver {
  var iterator: WebSocketInbound.AsyncIterator
  var advancing = false
  init(_ inbound: WebSocketInbound) { iterator = inbound.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    guard !advancing else { throw TunnelError.protocolViolation }
    advancing = true
    defer { advancing = false }
    var iterator = self.iterator
    let event = try await iterator.next(isolation: self)
    self.iterator = iterator
    switch event {
    case .message(.binary(let bytes)): return Bytes(bytes)
    case .message(.text): throw TunnelError.protocolViolation
    case .closed, nil: return nil
    }
  }
}
