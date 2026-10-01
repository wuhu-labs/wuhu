#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Serve
import ServeNIO
import Synchronization
import Testing

@Suite(.serialized)
struct WebSocketNIOTests {
  @Test func upgradesAndEchoesFramesOverTCP() async throws {
    try await withWebSocketServer(session: { socket in
      for await message in socket.inbound {
        try? await socket.send(message)
      }
      socket.close()
    }) { port in
      let client = try await connectWebSocket(port: port, path: "/ws")
      var inbound = client.frames.makeAsyncIterator()

      try await client.send(.binary, bytes: [1, 2, 3])
      let binaryEcho = try #require(await inbound.next())
      #expect(binaryEcho.opcode == .binary)
      #expect(bytes(of: binaryEcho) == [1, 2, 3])

      try await client.send(.text, bytes: Array("hello".utf8))
      let textEcho = try #require(await inbound.next())
      #expect(textEcho.opcode == .text)
      #expect(bytes(of: textEcho) == Array("hello".utf8))

      try await client.send(.connectionClose, bytes: [0x03, 0xE8])
      while let frame = await inbound.next() {
        if frame.opcode == .connectionClose {
          break
        }
      }
      try? await client.channel.close()
    }
  }

  @Test func pingIsAnsweredWithPong() async throws {
    try await withWebSocketServer(session: { socket in
      for await _ in socket.inbound {}
      socket.close()
    }) { port in
      let client = try await connectWebSocket(port: port, path: "/ws")
      try await client.send(.ping, bytes: [0xAB, 0xCD])

      var inbound = client.frames.makeAsyncIterator()
      let pong = try #require(await inbound.next())
      #expect(pong.opcode == .pong)
      #expect(bytes(of: pong) == [0xAB, 0xCD])
      try? await client.channel.close()
    }
  }

  @Test func serverCloseFinishesTheClient() async throws {
    try await withWebSocketServer(session: { socket in
      try? await socket.send(.text("bye"))
      socket.close()
    }) { port in
      let client = try await connectWebSocket(port: port, path: "/ws")
      var sawClose = false
      for await frame in client.frames where frame.opcode == .connectionClose {
        sawClose = true
        break
      }
      #expect(sawClose)
      try? await client.channel.close()
    }
  }

  @Test(.timeLimit(.minutes(1))) func abortReleasesBackpressuredWriteWithoutFlushingCloseFrame() async throws {
    let (sockets, continuation) = AsyncStream<WebSocket>.makeStream()
    let sendFinished = Signal()
    try await withWebSocketServer(session: { socket in
      continuation.yield(socket)
      for await _ in socket.inbound {}
    }) { port in
      let client = try await connectWebSocket(port: port, path: "/ws")
      try await client.channel.setOption(ChannelOptions.autoRead, value: false).get()
      var iterator = sockets.makeAsyncIterator()
      let socket = try #require(await iterator.next())
      let message = WebSocketMessage.binary(Array(repeating: 7, count: 32 << 20))
      await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          do {
            try await socket.send(message)
            sendFinished.trigger()
            return false
          } catch {
            sendFinished.trigger()
            return true
          }
        }
        group.addTask {
          try? await ContinuousClock().sleep(for: .milliseconds(100))
          #expect(!sendFinished.isTriggered)
          socket.close()
          try? await ContinuousClock().sleep(for: .milliseconds(100))
          #expect(!sendFinished.isTriggered)
          socket.abort()
          return true
        }
        for await failedOrAborted in group { #expect(failedOrAborted) }
      }
      #expect(sendFinished.isTriggered)
      try? await client.channel.close()
    }
  }

  @Test func refusedUpgradeReceivesTheHandlerResponse() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { request in
      guard request.headers["authorization"] == "Bearer good" else {
        return .response(Response(status: .unauthorized, body: .string("denied\n")))
      }
      return .webSocket { $0.close() }
    })
    do {
      let port = try #require(server.boundAddress.port)
      let response = try await rawRoundTrip(
        port: port,
        request: "GET /ws HTTP/1.1\r\nHost: local\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
      )
      #expect(response.hasPrefix("HTTP/1.1 401"))
      #expect(response.contains("denied"))
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func plainRequestsServeNormallyThroughAnUpgradingServer() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { request in
      .response(Response(status: .ok, body: .string("plain \(request.url.path)\n")))
    })
    do {
      let port = try #require(server.boundAddress.port)
      let response = try await rawRoundTrip(
        port: port,
        request: "GET /hello HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n",
      )
      #expect(response.hasPrefix("HTTP/1.1 200"))
      #expect(response.contains("plain /hello"))
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func shutdownCancelsLiveWebSocketSessions() async throws {
    let sessionEnded = Signal()
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .webSocket { socket in
        for await _ in socket.inbound {}
        sessionEnded.trigger()
      }
    })
    let port = try #require(server.boundAddress.port)
    let client = try await connectWebSocket(port: port, path: "/ws")
    try await client.send(.binary, bytes: [1])

    await server.shutdown()
    await sessionEnded.wait()
    try? await client.channel.close()
  }
}

private func withWebSocketServer(
  session: @escaping WebSocketSession,
  operation: (Int) async throws -> Void,
) async throws {
  let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { request in
    guard Serve.isWebSocketUpgradeRequest(request) else {
      return .response(Response(status: .badRequest))
    }
    return .webSocket(session)
  })
  do {
    try await operation(try #require(server.boundAddress.port))
    await server.shutdown()
  } catch {
    await server.shutdown()
    throw error
  }
}

private struct WebSocketTestClient: Sendable {
  let channel: Channel
  let frames: AsyncStream<WebSocketFrame>

  func send(_ opcode: WebSocketOpcode, bytes: [UInt8]) async throws {
    var buffer = channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    let frame = WebSocketFrame(fin: true, opcode: opcode, maskKey: [0x0A, 0x0B, 0x0C, 0x0D], data: buffer)
    try await channel.writeAndFlush(frame).get()
  }
}

private struct UpgradeRefused: Error {}

private func connectWebSocket(port: Int, path: String) async throws -> WebSocketTestClient {
  let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketTestClient>(
    upgradePipelineHandler: { channel, _ in
      channel.eventLoop.makeCompletedFuture {
        let collector = ClientFrameCollector()
        try channel.pipeline.syncOperations.addHandler(collector)
        return WebSocketTestClient(channel: channel, frames: collector.frames)
      }
    },
  )
  var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path)
  head.headers.add(name: "host", value: "127.0.0.1")
  let configuration = NIOTypedHTTPClientUpgradeConfiguration(
    upgradeRequestHead: head,
    upgraders: [upgrader],
    notUpgradingCompletionHandler: { channel in
      channel.eventLoop.makeFailedFuture(UpgradeRefused())
    },
  )
  let negotiation = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .connect(host: "127.0.0.1", port: port) { channel in
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
          configuration: .init(upgradeConfiguration: configuration),
        )
      }
    }
  return try await negotiation.get()
}

private final class ClientFrameCollector: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame

  let frames: AsyncStream<WebSocketFrame>
  private let continuation: AsyncStream<WebSocketFrame>.Continuation

  init() {
    (frames, continuation) = AsyncStream.makeStream()
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    continuation.yield(unwrapInboundIn(data))
  }

  func channelInactive(context: ChannelHandlerContext) {
    continuation.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error _: any Error) {
    continuation.finish()
    context.close(promise: nil)
  }
}

private func bytes(of frame: WebSocketFrame) -> [UInt8] {
  var buffer = frame.unmaskedData
  return buffer.readBytes(length: buffer.readableBytes) ?? []
}

private final class RawResponseCollector: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let promise: EventLoopPromise<String>
  private var collected = ""

  init(promise: EventLoopPromise<String>) {
    self.promise = promise
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    collected += buffer.readString(length: buffer.readableBytes) ?? ""
  }

  func channelInactive(context: ChannelHandlerContext) {
    promise.succeed(collected)
    context.fireChannelInactive()
  }

  func errorCaught(context _: ChannelHandlerContext, error: any Error) {
    promise.fail(error)
  }
}

private func rawRoundTrip(port: Int, request: String) async throws -> String {
  let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .connect(host: "127.0.0.1", port: port) { channel in
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(RawResponseCollector(promise: promise))
        return channel
      }
    }
  try await channel.writeAndFlush(channel.allocator.buffer(string: request))
  return try await promise.futureResult.get()
}

private final class Signal: Sendable {
  private let triggered = Mutex(false)
  var isTriggered: Bool { triggered.withLock { $0 } }
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func trigger() {
    triggered.withLock { $0 = true }
    continuation.finish()
  }

  func wait() async {
    for await _ in stream {}
  }
}
