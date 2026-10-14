#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchTunnel
import FetchTunnelWebSocket
import FetchWebSocket
import NIOCore
import NIOEmbedded
import NIOWebSocket
import Serve
@testable import ServeNIO
import ServeTunnel
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct BoundedWebSocketTests {
  @Test func tunnelOverBoundedTCPUpgrade() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .boundedWebSocket(limits: .init(), subprotocol: TunnelTransport.webSocketSubprotocol) { transport in
        try? await ServeTunnel.run(handler: { request in .init(status: .created, body: request.body ?? .empty) }, over: transport)
      }
    })
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.boundAddress.port))/tunnel")!
      let transport = try await TunnelWebSocket.connect(.init(url: url))
      let tunnel = try Tunnel(over: transport)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try? await tunnel.run() }
        let response = try await tunnel.client(Request(url: URL(string: "https://example.test/any-route")!, method: .put, body: .string("binary body")))
        #expect(response.status == .created)
        #expect(try await response.body.text() == "binary body")
        await tunnel.abort()
        group.cancelAll()
      }
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  @Test func serverRequiresOfferedSubprotocol() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .boundedWebSocket(limits: .init(), subprotocol: TunnelTransport.webSocketSubprotocol) { $0.abort() }
    })
    do {
      let port = try #require(server.boundAddress.port)
      do {
        _ = try await WebSocketConnector.live.connect(.init(url: URL(string: "ws://127.0.0.1:\(port)/")!))
        Issue.record("missing subprotocol accepted")
      } catch WebSocketError.refused(let status, _, _) { #expect(status == 400) }
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  @Test func fragmentedMessageLimitAndQueueOverflowAreTyped() async throws {
    for queued in [false, true] {
      let bridge = BoundedWebSocketBridge(limits: .init(messageBytes: 3, bufferedReceiveBytes: 1))
      let channel = EmbeddedChannel(handler: bridge)
      let transport = bridge.transport(channel: channel)
      if queued {
        try channel.writeInbound(frame(.binary, []))
        try channel.writeInbound(frame(.binary, []))
      } else {
        try channel.writeInbound(frame(.binary, [1, 2], fin: false))
        try channel.writeInbound(frame(.continuation, [3, 4]))
      }
      channel.embeddedEventLoop.run()
      await #expect(throws: TunnelError.webSocketLimitExceeded) {
        while try await transport.receive() != nil {}
      }
      _ = try channel.finish(acceptAlreadyClosed: true)
    }
  }

  @Test(arguments: [0, 1])
  func tinyMessagesHaveAQueueOverheadFloor(payloadBytes: Int) async throws {
    let bridge = BoundedWebSocketBridge(limits: .init(messageBytes: 2048, bufferedReceiveBytes: 4096))
    let channel = EmbeddedChannel(handler: bridge)
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
    let transport = bridge.transport(channel: channel)
    #expect(transport.maxMessageBytes == 2048)
    for _ in 0 ..< 4 { try channel.writeInbound(frame(.binary, Array(repeating: 1, count: payloadBytes))) }
    #expect(channel.isActive)
    try channel.writeInbound(frame(.binary, Array(repeating: 1, count: payloadBytes)))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    if channel.isActive { try await channel.close().get() }
    var received = 0
    await #expect(throws: TunnelError.webSocketLimitExceeded) {
      while try await transport.receive() != nil { received += 1 }
    }
    #expect(received == 4)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func stalledPongsHaveAFixedCountBound() async throws {
    let writes = StalledBoundedControlWrites()
    let bridge = BoundedWebSocketBridge(limits: .init())
    let channel = EmbeddedChannel(handlers: [writes, bridge])
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
    let transport = bridge.transport(channel: channel)
    for _ in 0 ..< 16 { try channel.writeInbound(frame(.ping, [])) }
    #expect(channel.isActive)
    #expect(writes.count == 16)
    try channel.writeInbound(frame(.ping, []))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    #expect(writes.count == 16)
    if channel.isActive { try await channel.close().get() }
    await #expect(throws: TunnelError.capacityExceeded) { try await transport.receive() }
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func consumedMessagesReleaseTheirFullCharge() async throws {
    let bridge = BoundedWebSocketBridge(limits: .init(messageBytes: 2048, bufferedReceiveBytes: 4096))
    let channel = EmbeddedChannel(handler: bridge)
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
    let transport = bridge.transport(channel: channel)
    let large = Array(repeating: UInt8(1), count: 2048)
    try channel.writeInbound(frame(.binary, large))
    try channel.writeInbound(frame(.binary, []))
    try channel.writeInbound(frame(.binary, [2]))
    #expect(try await transport.receive() == Bytes(large))
    try channel.writeInbound(frame(.binary, []))
    try channel.writeInbound(frame(.binary, []))
    #expect(channel.isActive)
    #expect(try await transport.receive() == Bytes())
    try channel.writeInbound(frame(.binary, []))
    #expect(channel.isActive)
    try channel.writeInbound(frame(.binary, []))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    if channel.isActive { try await channel.close().get() }
    var received = 0
    await #expect(throws: TunnelError.webSocketLimitExceeded) {
      while try await transport.receive() != nil { received += 1 }
    }
    #expect(received == 4)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func completedPongsReleaseTheirSlots() async throws {
    let writes = StalledBoundedControlWrites()
    let bridge = BoundedWebSocketBridge(limits: .init())
    let channel = EmbeddedChannel(handlers: [writes, bridge])
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
    for _ in 0 ..< 16 { try channel.writeInbound(frame(.ping, [])) }
    writes.complete()
    channel.embeddedEventLoop.run()
    for _ in 0 ..< 16 { try channel.writeInbound(frame(.ping, [])) }
    #expect(channel.isActive)
    #expect(writes.count == 32)
    _ = try channel.finish()
  }

  @Test func pongsRefuseNonWritableChannels() async throws {
    let writes = StalledBoundedControlWrites()
    let bridge = BoundedWebSocketBridge(limits: .init())
    let channel = EmbeddedChannel(handlers: [writes, bridge])
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
    let transport = bridge.transport(channel: channel)
    channel.isWritable = false
    try channel.writeInbound(frame(.ping, []))
    channel.embeddedEventLoop.run()
    #expect(!channel.isActive)
    #expect(writes.count == 0)
    if channel.isActive { try await channel.close().get() }
    await #expect(throws: TunnelError.capacityExceeded) { try await transport.receive() }
    _ = try channel.finish(acceptAlreadyClosed: true)
  }

  @Test func unexpectedContinuationIsTyped() async throws {
    let bridge = BoundedWebSocketBridge(limits: .init())
    let channel = EmbeddedChannel(handler: bridge)
    let transport = bridge.transport(channel: channel)
    try channel.writeInbound(frame(.continuation, [1]))
    channel.embeddedEventLoop.run()
    await #expect(throws: TunnelError.protocolViolation) { try await transport.receive() }
    _ = try channel.finish(acceptAlreadyClosed: true)
  }
}

private func frame(_ opcode: WebSocketOpcode, _ bytes: [UInt8], fin: Bool = true) -> WebSocketFrame {
  WebSocketFrame(fin: fin, opcode: opcode, maskKey: [0, 0, 0, 0], data: ByteBufferAllocator().buffer(bytes: bytes))
}

private final class StalledBoundedControlWrites: ChannelOutboundHandler {
  typealias OutboundIn = WebSocketFrame
  var count = 0
  var pending: [EventLoopPromise<Void>] = []

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    count += 1
    if let promise { pending.append(promise) }
  }

  func flush(context: ChannelHandlerContext) {}

  func complete() {
    for pending in pending { pending.succeed(()) }
    pending.removeAll()
  }

  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    context.close(mode: mode, promise: promise)
    for pending in pending { pending.fail(ChannelError.ioOnClosedChannel) }
    pending.removeAll()
  }
}
