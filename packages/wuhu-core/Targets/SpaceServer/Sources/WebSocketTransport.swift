import protocol MachineChannel.FrameTransport
import Serve

// Bridges a wuhu-serve WebSocket into MachineChannel's FrameTransport, both
// for in-process caller legs (the session runtime's exec backend) and for
// test harnesses driving real ChannelEndpoint / MachineAgent legs.
public final class WebSocketTransport: FrameTransport, Sendable {
  public let inbound: AsyncStream<[UInt8]>
  private let socket: WebSocket

  public init(_ socket: WebSocket) {
    self.socket = socket
    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    inbound = stream
    Task {
      for await message in socket.inbound {
        switch message {
        case let .binary(bytes): continuation.yield(bytes)
        case let .text(text): continuation.yield(Array(text.utf8))
        }
      }
      continuation.finish()
    }
  }

  public func send(_ frame: [UInt8]) async throws {
    try await socket.send(.binary(frame))
  }

  public func close() {
    socket.close()
  }
}
