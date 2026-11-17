import protocol MachineChannel.FrameTransport
import Serve

public final class WebSocketTransport: FrameTransport, Sendable {
  public let inbound: AsyncStream<[UInt8]>
  private let socket: WebSocket

  public init(_ socket: WebSocket) {
    self.socket = socket
    let source = SocketFrames(socket)
    inbound = AsyncStream(unfolding: { await source.next() }, onCancel: { socket.close() })
  }

  public func send(_ frame: [UInt8]) async throws { try await socket.send(.binary(frame)) }
  public func close() { socket.close() }
}

private actor SocketFrames {
  private var iterator: AsyncStream<WebSocketMessage>.Iterator?
  private let socket: WebSocket
  init(_ socket: WebSocket) { self.socket = socket; iterator = socket.inbound.makeAsyncIterator() }
  func next() async -> [UInt8]? {
    guard var iterator = self.iterator else { return nil }
    self.iterator = nil
    guard let message = await iterator.next(isolation: self) else { socket.close(); return nil }
    self.iterator = iterator
    switch message {
    case let .binary(bytes): return bytes
    case let .text(text): return Array(text.utf8)
    }
  }
}
