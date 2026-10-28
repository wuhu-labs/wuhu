public enum ChannelError: Error, Equatable, Sendable {
  case severed
  case protocolViolation(String)
}

public protocol FrameTransport: Sendable {
  var inbound: AsyncStream<[UInt8]> { get }
  func send(_ frame: [UInt8]) async throws
  func close()
}
