#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import FetchWebSocket
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing

@Suite(.serialized)
struct FetchWebSocketFragmentationTests {
  @Test func concurrentFragmentedSendsKeepDataMessagesContiguousWithControlFrames() async throws {
    let captured = CapturedFrames()
    try await withControlledWrites(captured: captured, messages: 2, failContinuation: false) { socket in
      let gate = AsyncStream<Void>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { group in
        for byte: UInt8 in [17, 29] {
          group.addTask {
            for await _ in gate.stream { break }
            try await socket.send(.binary(Array(repeating: byte, count: (32 << 20) + 1)))
          }
        }
        gate.continuation.yield(())
        gate.continuation.yield(())
        gate.continuation.finish()
        try await group.waitForAll()
      }
      let frames = captured.frames.withLock { $0 }
      let data = frames.filter { $0.opcode == .binary || $0.opcode == .continuation }
      #expect(data.count == 6)
      #expect(frames.filter { $0.opcode == .pong }.count == 2)
      var starts: [UInt8] = []
      for offset in stride(from: 0, to: data.count, by: 3) {
        let message = Array(data[offset ..< offset + 3])
        #expect(message.map(\.opcode) == [.binary, .continuation, .continuation])
        #expect(message.map(\.fin) == [false, false, true])
        let byte = try #require(message[0].data.getInteger(at: 0, as: UInt8.self))
        starts.append(byte)
        for frame in message {
          #expect(frame.maskKey != nil)
          #expect(Data(frame.data.readableBytesView) == Data(repeating: byte, count: frame.data.readableBytes))
        }
      }
      #expect(Set(starts) == [17, 29])
    }
  }

  @Test func failingMiddleContinuationWriteFailsSendEvenWhenFinalWriteSucceeds() async throws {
    let captured = CapturedFrames()
    try await withControlledWrites(captured: captured, messages: 1, failContinuation: true) { socket in
      await #expect(throws: WebSocketError.io("injected continuation write failure")) {
        try await socket.send(.binary(Array(repeating: 31, count: (32 << 20) + 1)))
      }
      let data = captured.frames.withLock { $0.filter { $0.opcode == .binary || $0.opcode == .continuation } }
      #expect(data.map(\.opcode) == [.binary, .continuation, .continuation])
      #expect(data.map(\.fin) == [false, false, true])
    }
  }

  @Test(arguments: [0, (16 << 20) - 1, 16 << 20, (16 << 20) + 1, 32 << 20, (32 << 20) + 1], [false, true])
  func largeMessagesUseContinuationFramesWithoutChangingSmallMessages(size: Int, text: Bool) async throws {
    let captured = CapturedFrames()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 16 << 20, shouldUpgrade: { channel, _ in
          channel.eventLoop.makeSucceededFuture(HTTPHeaders())
        }, upgradePipelineHandler: { channel, _ in
          channel.pipeline.addHandler(CaptureFragments(captured))
        })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let port = try #require(server.localAddress?.port)
      let socket = try await WebSocketConnector.live.connect(.init(url: URL(string: "ws://127.0.0.1:\(port)/")!, limits: .init(outboundMessageBytes: 128 << 20)))
      let string = size >= 3 ? String(repeating: "x", count: size - 3) + "€" : String(repeating: "x", count: size)
      let message: WebSocketMessage = text ? .text(string) : .binary(Array(repeating: 255, count: size))
      try await socket.send(message)
      var inbound = socket.inbound.makeAsyncIterator()
      #expect(try await inbound.next() == .message(.text("accepted")))
      let frames = captured.frames.withLock { $0 }
      #expect(frames.count == max(1, (size + (16 << 20) - 1) / (16 << 20)))
      var bytes: [UInt8] = []
      for (index, frame) in frames.enumerated() {
        #expect(frame.maskKey != nil)
        #expect(frame.opcode == (index == 0 ? (text ? .text : .binary) : .continuation))
        #expect(frame.fin == (index == frames.count - 1))
        #expect(frame.data.readableBytes == min(16 << 20, size - bytes.count))
        #expect(!frame.rsv1 && !frame.rsv2 && !frame.rsv3)
        var data = frame.unmaskedData
        bytes += data.readBytes(length: data.readableBytes) ?? []
      }
      #expect(bytes == (text ? Array(string.utf8) : Array(repeating: 255, count: size)))
      socket.abort()
      try await server.close().get()
    } catch {
      try? await server.close().get()
      throw error
    }
  }
}

private final class CaptureFragments: ChannelInboundHandler, Sendable {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  let captured: CapturedFrames

  init(_ captured: CapturedFrames) { self.captured = captured }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    guard frame.opcode == .text || frame.opcode == .binary || frame.opcode == .continuation else { return }
    captured.frames.withLock { $0.append(frame) }
    if frame.fin {
      context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .text, data: context.channel.allocator.buffer(string: "accepted"))), promise: nil)
    }
  }
}

private final class CapturedFrames: Sendable { let frames = Mutex<[WebSocketFrame]>([]) }

private func withControlledWrites(
  captured: CapturedFrames, messages: Int, failContinuation: Bool,
  operation: (WebSocketConnection) async throws -> Void,
) async throws {
  let group = MultiThreadedEventLoopGroup.singleton
  let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
  let channel = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: server.localAddress!.port!).get()
  do {
    let connection = try await channel.eventLoop.submit {
      let bridge = MessageBridge(limits: .init(outboundMessageBytes: 128 << 20))
      try channel.pipeline.syncOperations.addHandler(ControlledFragmentWrites(captured: captured, messages: messages, failContinuation: failContinuation))
      try channel.pipeline.syncOperations.addHandler(bridge)
      return bridge.connection(channel: channel, headers: Headers(), closeTimeout: .seconds(1))
    }.get()
    try await operation(connection)
    try await channel.close().get()
    try await server.close().get()
  } catch {
    try? await channel.close().get()
    try? await server.close().get()
    throw error
  }
}

private final class ControlledFragmentWrites: ChannelOutboundHandler {
  typealias OutboundIn = WebSocketFrame
  let captured: CapturedFrames
  let failContinuation: Bool
  private var continuationCount = 0
  private var completedMessages = 0
  private var pendingWrites: [EventLoopPromise<Void>] = []
  private let messages: Int

  init(captured: CapturedFrames, messages: Int, failContinuation: Bool) {
    self.captured = captured
    self.failContinuation = failContinuation
    self.messages = messages
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let frame = unwrapOutboundIn(data)
    captured.frames.withLock { $0.append(frame) }
    if frame.opcode == .continuation { continuationCount += 1 }
    if failContinuation && frame.opcode == .continuation && continuationCount == 1 {
      promise?.fail(WebSocketError.io("injected continuation write failure"))
    } else if frame.opcode == .pong { promise?.succeed(()) }
    else if let promise { pendingWrites.append(promise) }
    if frame.fin && (frame.opcode == .binary || frame.opcode == .continuation) {
      completedMessages += 1
      if completedMessages == messages {
        // Neither concurrent send can finish before both complete frame batches arrive.
        for pending in pendingWrites { pending.succeed(()) }
        pendingWrites.removeAll()
      }
    }
    if frame.opcode == .binary {
      let control = context.channel.allocator.buffer(string: "probe")
      context.fireChannelRead(NIOAny(WebSocketFrame(fin: true, opcode: .ping, data: control)))
      context.fireChannelRead(NIOAny(WebSocketFrame(fin: true, opcode: .pong, data: control)))
    }
  }

  func flush(context: ChannelHandlerContext) {}
}
