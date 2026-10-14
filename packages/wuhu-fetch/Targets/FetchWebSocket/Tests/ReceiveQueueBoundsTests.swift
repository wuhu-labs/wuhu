import Fetch
@testable import FetchWebSocket
import NIOCore
import NIOEmbedded
import NIOWebSocket
import Testing

@Suite(.serialized)
struct ReceiveQueueBoundsTests {
  @Test(arguments: [0, 1])
  func tinyMessagesHaveAQueueOverheadFloor(payloadBytes: Int) async throws {
    let (channel, socket) = try connection(bufferedReceiveBytes: 4096)
    for _ in 0 ..< 4 { try channel.writeInbound(binary(Array(repeating: 1, count: payloadBytes))) }
    #expect(channel.isActive)
    try channel.writeInbound(binary(Array(repeating: 1, count: payloadBytes)))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    if channel.isActive { try await channel.close().get() }
    var received = 0
    await #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) {
      for try await _ in socket.inbound { received += 1 }
    }
    #expect(received == 4)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func consumedMessagesReleaseTheirFullCharge() async throws {
    let (channel, socket) = try connection(bufferedReceiveBytes: 4096)
    let large = Array(repeating: UInt8(1), count: 2048)
    try channel.writeInbound(binary(large))
    try channel.writeInbound(binary([]))
    try channel.writeInbound(binary([2]))
    var inbound = socket.inbound.makeAsyncIterator()
    #expect(try await inbound.next() == .message(.binary(large)))
    try channel.writeInbound(binary([]))
    try channel.writeInbound(binary([]))
    #expect(channel.isActive)
    #expect(try await inbound.next() == .message(.binary([])))
    try channel.writeInbound(binary([]))
    #expect(channel.isActive)
    try channel.writeInbound(binary([]))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    if channel.isActive { try await channel.close().get() }
    var received = 0
    await #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) {
      while try await inbound.next() != nil { received += 1 }
    }
    #expect(received == 4)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func legacyUnboundedBudgetAcceptsMoreThanDefaultQueueCount() async throws {
    let (channel, socket) = try connection(bufferedReceiveBytes: Int.max)
    for _ in 0 ..< 1025 { try channel.writeInbound(binary([])) }
    #expect(channel.isActive)
    var inbound = socket.inbound.makeAsyncIterator()
    for _ in 0 ..< 1025 { #expect(try await inbound.next() == .message(.binary([]))) }
    _ = try channel.finish()
  }
}

private func connection(bufferedReceiveBytes: Int) throws -> (EmbeddedChannel, WebSocketConnection) {
  let channel = EmbeddedChannel()
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
  let bridge = MessageBridge(limits: .init(bufferedReceiveBytes: bufferedReceiveBytes))
  try channel.pipeline.syncOperations.addHandler(bridge)
  return (channel, bridge.connection(channel: channel, headers: Headers(), closeTimeout: .seconds(1)))
}

private func binary(_ bytes: [UInt8]) -> WebSocketFrame {
  WebSocketFrame(fin: true, opcode: .binary, data: ByteBufferAllocator().buffer(bytes: bytes))
}
