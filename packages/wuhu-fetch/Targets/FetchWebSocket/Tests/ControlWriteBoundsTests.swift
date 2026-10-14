import Fetch
@testable import FetchWebSocket
import NIOCore
import NIOEmbedded
import NIOWebSocket
import Testing

@Suite(.serialized)
struct ControlWriteBoundsTests {
  @Test func stalledPongsHaveAFixedCountBound() async throws {
    let writes = StalledControlWrites()
    let (channel, socket) = try connection(writes: writes)
    for _ in 0 ..< 16 { try channel.writeInbound(control(.ping)) }
    #expect(channel.isActive)
    #expect(writes.count == 16)
    try channel.writeInbound(control(.ping))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    #expect(writes.count == 16)
    if channel.isActive { try await channel.close().get() }
    await #expect(throws: WebSocketError.limitExceeded(.outboundMessage)) {
      var inbound = socket.inbound.makeAsyncIterator()
      _ = try await inbound.next()
    }
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func completedPongsReleaseTheirSlots() throws {
    let writes = StalledControlWrites()
    let (channel, _) = try connection(writes: writes)
    for _ in 0 ..< 16 { try channel.writeInbound(control(.ping)) }
    writes.complete()
    channel.embeddedEventLoop.run()
    for _ in 0 ..< 16 { try channel.writeInbound(control(.ping)) }
    #expect(channel.isActive)
    #expect(writes.count == 32)
    _ = try channel.finish()
  }

  @Test(arguments: [WebSocketOpcode.ping, .connectionClose])
  func controlRepliesRefuseNonWritableChannels(opcode: WebSocketOpcode) throws {
    let writes = StalledControlWrites()
    let (channel, _) = try connection(writes: writes)
    channel.isWritable = false
    try channel.writeInbound(control(opcode))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    #expect(writes.count == 0)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test(arguments: [WebSocketOpcode.ping, .connectionClose])
  func legacyUnboundedControlRepliesKeepQueuingAfterLargeSend(opcode: WebSocketOpcode) throws {
    let writes = StalledControlWrites()
    let (channel, _) = try connection(writes: writes, limits: .init(messageBytes: Int.max, bufferedReceiveBytes: Int.max, outboundMessageBytes: Int.max))
    channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: channel.allocator.buffer(bytes: Array(repeating: 42, count: 2 << 20))), promise: nil)
    channel.isWritable = false
    let count = opcode == .ping ? 17 : 1
    for _ in 0 ..< count { try channel.writeInbound(control(opcode)) }
    channel.embeddedEventLoop.run()
    #expect(writes.count == count + 1)
    if opcode == .ping { #expect(channel.isActive) }
    _ = try channel.finish(acceptAlreadyClosed: true)
  }
}

private func connection(writes: StalledControlWrites, limits: WebSocketLimits = .init()) throws -> (EmbeddedChannel, WebSocketConnection) {
  let channel = EmbeddedChannel(handler: writes)
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
  let bridge = MessageBridge(limits: limits)
  try channel.pipeline.syncOperations.addHandler(bridge)
  return (channel, bridge.connection(channel: channel, headers: Headers(), closeTimeout: .seconds(1)))
}

private func control(_ opcode: WebSocketOpcode) -> WebSocketFrame {
  WebSocketFrame(fin: true, opcode: opcode, data: ByteBufferAllocator().buffer(capacity: 0))
}

private final class StalledControlWrites: ChannelOutboundHandler {
  typealias OutboundIn = WebSocketFrame
  var count = 0
  var pending: [EventLoopPromise<Void>] = []

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    count += 1
    if let promise { pending.append(promise) }
  }

  func flush(context: ChannelHandlerContext) {}

  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    context.close(mode: mode, promise: promise)
    for pending in pending { pending.fail(ChannelError.ioOnClosedChannel) }
    pending.removeAll()
  }

  func complete() {
    for pending in pending { pending.succeed(()) }
    pending.removeAll()
  }
}
