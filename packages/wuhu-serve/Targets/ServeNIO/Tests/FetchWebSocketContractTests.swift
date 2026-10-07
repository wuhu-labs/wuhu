#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchWebSocket
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Serve
import ServeNIO
import Synchronization
import Testing

@Suite(.serialized)
struct FetchWebSocketContractTests {
  @Test func typedTextBinaryAndClose() async throws {
    try await withFrames([
      frame(.text, [0xE2], fin: false), frame(.continuation, [0x82, 0xAC]),
      frame(.binary, [0, 255]), frame(.connectionClose, [0x0F, 0xA1] + Array("bye".utf8)),
    ]) { url in
      let socket = try await WebSocketConnector.live.connect(.init(url: url))
      #expect(socket.responseHeaders[.init("x-upgrade")!] == "accepted")
      var iterator = socket.inbound.makeAsyncIterator()
      #expect(try await iterator.next() == .message(.text("€")))
      #expect(try await iterator.next() == .message(.binary([0, 255])))
      #expect(try await iterator.next() == .closed(.init(code: 4001, reason: "bye")))
      #expect(try await iterator.next() == nil)
    }
  }

  @Test func refusalKeepsStatusHeadersAndBoundedBody() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .response(.text("0123456789", status: .tooManyRequests, headers: [.retryAfter: "7"]))
    })
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.boundAddress.port))/")!
      do {
        _ = try await WebSocketConnector.live.connect(.init(url: url, limits: .init(refusalBodyBytes: 4)))
        Issue.record("upgrade unexpectedly accepted")
      } catch WebSocketError.refused(let status, let headers, let body) {
        #expect(status == 429)
        #expect(headers[.retryAfter] == "7")
        #expect(body == Array("0123".utf8))
      }
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  @Test(arguments: [
    [frame(.text, [255])],
    [frame(.continuation, [1])],
    [frame(.text, [1], fin: false), frame(.text, [2])],
    [frame(.connectionClose, [1])],
    [frame(.connectionClose, [3, 237])],
    [frame(.connectionClose, [3, 232, 255])],
    [frame(.binary, [1], maskKey: [1, 2, 3, 4])],
    [frame(.ping, [1], fin: false)],
    [frame(.pong, Array(repeating: 1, count: 126))],
  ])
  func invalidWireIsTyped(frames: [WebSocketFrame]) async throws {
    try await withFrames(frames) { url in
      let socket = try await WebSocketConnector.live.connect(.init(url: url))
      defer { socket.abort() }
      do {
        for try await _ in socket.inbound {}
        Issue.record("invalid wire ended successfully")
      } catch WebSocketError.protocolViolation {} catch { Issue.record("unexpected error: \(error)") }
    }
  }

  @Test func frameLimit() async throws {
    try await withFrames([frame(.binary, Array(repeating: 1, count: 65))]) { url in
      let socket = try await WebSocketConnector.live.connect(.init(url: url, limits: .init(frameBytes: 64)))
      defer { socket.abort() }
      await #expect(throws: WebSocketError.limitExceeded(.frame)) { for try await _ in socket.inbound {} }
    }
  }

  @Test func assembledMessageLimit() async throws {
    try await withFrames([frame(.text, [1, 2], fin: false), frame(.continuation, [3, 4])]) { url in
      let socket = try await WebSocketConnector.live.connect(.init(url: url, limits: .init(messageBytes: 3)))
      defer { socket.abort() }
      await #expect(throws: WebSocketError.limitExceeded(.message)) { for try await _ in socket.inbound {} }
    }
  }

  @Test func bufferedByteLimitIncludesEmptyMessages() async throws {
    let ended = AsyncStream<Void>.makeStream()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.closeFuture.whenComplete { _ in ended.continuation.yield(()); ended.continuation.finish() }
        let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) }, upgradePipelineHandler: { channel, _ in
          channel.write(frame(.binary, []), promise: nil)
          channel.write(frame(.binary, []), promise: nil)
          channel.writeAndFlush(frame(.connectionClose, [3, 232]), promise: nil)
          return channel.eventLoop.makeSucceededVoidFuture()
        })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      let socket = try await WebSocketConnector.live.connect(.init(url: url, limits: .init(bufferedReceiveBytes: 1)))
      defer { socket.abort() }
      for await _ in ended.stream { break }
      await #expect(throws: WebSocketError.limitExceeded(.bufferedReceive)) { for try await _ in socket.inbound {} }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test(arguments: [WebSocketClose(code: 999), .init(code: 1005), .init(code: 1006), .init(code: 1015), .init(code: 5000), .init(reason: String(repeating: "é", count: 62))])
  func outboundCloseValidation(close: WebSocketClose) async throws {
    try await withFrames([]) { url in
      let socket = try await WebSocketConnector.live.connect(.init(url: url))
      defer { socket.abort() }
      await #expect(throws: WebSocketError.protocolViolation("invalid close")) { try await socket.close(close) }
    }
  }

  @Test func textSendOutboundLimitAndSingleConsumer() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .webSocket { socket in
        for await message in socket.inbound { try? await socket.send(message) }
      }
    })
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.boundAddress.port))/")!
      let socket = try await WebSocketConnector.live.connect(.init(url: url, limits: .init(outboundMessageBytes: 3)))
      var iterator = socket.inbound.makeAsyncIterator()
      var duplicate = socket.inbound.makeAsyncIterator()
      await #expect(throws: WebSocketError.multipleConsumers) { _ = try await duplicate.next() }
      try await socket.send(.text("hey"))
      #expect(try await iterator.next() == .message(.text("hey")))
      await #expect(throws: WebSocketError.limitExceeded(.outboundMessage)) { try await socket.send(.text("four")) }
      try await socket.close()
      #expect(try await iterator.next() == .closed(.init()))
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  @Test func abruptEOFIsNotNormalClose() async throws {
    try await withFrames([], disconnect: true) { url in
      await #expect(throws: WebSocketError.connectionClosed) {
        let socket = try await WebSocketConnector.live.connect(.init(url: url))
        for try await _ in socket.inbound {}
      }
    }
  }

  @Test func abortAndBoundedGracefulClose() async throws {
    try await withFrames([]) { url in
      let socket = try await WebSocketConnector.live.connect(.init(url: url, closeTimeout: .milliseconds(1)))
      try await socket.close()
      await #expect(throws: WebSocketError.connectionClosed) { for try await _ in socket.inbound {} }
      let second = try await WebSocketConnector.live.connect(.init(url: url))
      second.abort()
      await #expect(throws: WebSocketError.cancelled) { for try await _ in second.inbound {} }
    }
  }

  @Test func cancellationBeforeAndDuringDialClosesChannel() async throws {
    let (accepted, signal) = AsyncStream<Void>.makeStream()
    let (disconnected, ended) = AsyncStream<Void>.makeStream()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.closeFuture.whenComplete { _ in ended.yield(()) }
        signal.yield(())
        return channel.eventLoop.makeSucceededVoidFuture()
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      let dial = Task { try await WebSocketConnector.live.connect(.init(url: url)) }
      var acceptedIterator = accepted.makeAsyncIterator()
      _ = await acceptedIterator.next()
      dial.cancel()
      await #expect(throws: CancellationError.self) { _ = try await dial.value }
      var disconnectedIterator = disconnected.makeAsyncIterator()
      _ = await disconnectedIterator.next()
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test func cancelledBeforeDialAndInvalidConfiguration() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let dial = Task {
      var iterator = gate.makeAsyncIterator()
      _ = await iterator.next()
      return try await WebSocketConnector.live.connect(.init(url: URL(string: "ws://127.0.0.1:1/")!))
    }
    dial.cancel()
    release.yield(())
    release.finish()
    await #expect(throws: CancellationError.self) { _ = try await dial.value }
    var request = WebSocketRequest(url: URL(string: "ws://127.0.0.1:1/")!)
    request.limits.frameBytes = 0
    await #expect(throws: WebSocketError.invalidConfiguration("invalid limits or timeouts")) {
      _ = try await WebSocketConnector.live.connect(request)
    }
  }

  @Test func constructibleConnectionOverServePair() async throws {
    let (client, server) = WebSocket.pair()
    let (events, continuation) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await message in client.inbound {
          switch message {
          case .text(let text): continuation.yield(.message(.text(text)))
          case .binary(let bytes): continuation.yield(.message(.binary(bytes)))
          }
        }
        continuation.finish()
      }
      let connection = WebSocketConnection(inbound: .init(events), send: { message in
        switch message {
        case .text(let text): try await client.send(.text(text))
        case .binary(let bytes): try await client.send(.binary(bytes))
        }
      }, close: { _ in client.close() }, abort: { client.abort() })
      try await connection.send(.text("request"))
      var serverIterator = server.inbound.makeAsyncIterator()
      #expect(await serverIterator.next() == .text("request"))
      try await server.send(.binary([7]))
      var iterator = connection.inbound.makeAsyncIterator()
      #expect(try await iterator.next() == .message(.binary([7])))
      try await connection.close()
      try await group.waitForAll()
    }
  }
}

private func frame(_ opcode: WebSocketOpcode, _ bytes: [UInt8], fin: Bool = true, maskKey: WebSocketMaskingKey? = nil) -> WebSocketFrame {
  WebSocketFrame(fin: fin, opcode: opcode, maskKey: maskKey, data: ByteBuffer(bytes: bytes))
}

private func withFrames(_ frames: [WebSocketFrame], disconnect: Bool = false, operation: (URL) async throws -> Void) async throws {
  let clients = Mutex<[any Channel]>([])
  let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .childChannelInitializer { channel in
      clients.withLock { $0.append(channel) }
      let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, _ in
        channel.eventLoop.makeSucceededFuture(HTTPHeaders([("x-upgrade", "accepted")]))
      }, upgradePipelineHandler: { channel, _ in
        for frame in frames { channel.write(frame, promise: nil) }
        channel.flush()
        if disconnect { channel.close(promise: nil) }
        return channel.eventLoop.makeSucceededVoidFuture()
      })
      return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
        upgraders: [upgrader], completionHandler: { _ in },
      ))
    }.bind(host: "127.0.0.1", port: 0).get()
  do {
    try await operation(URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!)
    for client in clients.withLock({ $0 }) { try? await client.close().get() }
    try await server.close().get()
  } catch {
    for client in clients.withLock({ $0 }) { try? await client.close().get() }
    try? await server.close().get()
    throw error
  }
}
