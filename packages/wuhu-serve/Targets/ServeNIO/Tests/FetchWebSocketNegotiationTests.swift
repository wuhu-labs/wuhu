#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FetchWebSocket
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Synchronization
import Testing

@Suite(.serialized)
struct FetchWebSocketNegotiationTests {
  @Test(arguments: [false, true])
  func refusalHeadWinsOverEmptyBodyEOFAndReset(reset: Bool) async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: reset ? 1 : 8192))
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(RefusalThenClose(reset: reset)) }
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      let request = WebSocketRequest(url: url, headers: .init(values: reset ? ["x-unread": String(repeating: "x", count: 128 * 1024)] : [:]), connectTimeout: .seconds(2))
      do {
        _ = try await WebSocketConnector.live.connect(request)
        Issue.record("unexpected acceptance")
      } catch WebSocketError.refused(let status, let headers, let body) {
        #expect(status == 502)
        #expect(headers[.init("x-refusal")!] == "kept")
        #expect(body == (reset ? Array("nope".utf8) : []))
      } catch { Issue.record("refusal replaced by later EOF/reset: \(error)") }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test func connectTimeoutBoundsSilentUpgradeAndClosesHalfOpenSocket() async throws {
    let ended = AsyncStream<Void>.makeStream()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.closeFuture.whenComplete { _ in ended.continuation.yield(()); ended.continuation.finish() }
        return channel.eventLoop.makeSucceededVoidFuture()
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      let clock = ContinuousClock()
      let start = clock.now
      await #expect(throws: WebSocketError.connectTimeout) {
        _ = try await WebSocketConnector.live.connect(.init(url: url, connectTimeout: .milliseconds(100)))
      }
      #expect(start.duration(to: clock.now) < .seconds(2))
      for await _ in ended.stream { break }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test func legacyRepeatedHeadersRemainSeparateFields() async throws {
    let received = Mutex<[String]>([])
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, request in
          received.withLock { $0 = request.headers["x-trace"] }
          return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
        }, upgradePipelineHandler: { channel, _ in channel.eventLoop.makeSucceededVoidFuture() })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      let socket = try await WebSocketClient.connect(url: url, headers: [("X-Trace", "one"), ("x-trace", "two"), ("X-Trace", "three")])
      #expect(received.withLock { $0 } == ["one", "two", "three"])
      socket.close()
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test(arguments: [0, 4])
  func hugeUnfinishedRefusalHasBoundedCapture(limit: Int) async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UnfinishedRefusal()) }
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      do {
        _ = try await WebSocketConnector.live.connect(.init(url: url, limits: .init(refusalBodyBytes: limit), connectTimeout: .seconds(2)))
        Issue.record("unexpected acceptance")
      } catch WebSocketError.refused(let status, let headers, let body) {
        #expect(status == 429)
        #expect(headers[.retryAfter] == "7")
        #expect(body == Array(repeating: UInt8(ascii: "x"), count: limit))
      } catch { Issue.record("refusal waited for an unfinished oversized body: \(error)") }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test func cancellationWhileClosingThrows() async throws {
    let (seen, signal) = AsyncStream<Void>.makeStream()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, _ in
          channel.eventLoop.makeSucceededFuture(HTTPHeaders())
        }, upgradePipelineHandler: { channel, _ in
          channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(HoldClose(signal: signal)) }
        })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      let socket = try await WebSocketConnector.live.connect(.init(url: url))
      let closing = Task { try await socket.close() }
      var iterator = seen.makeAsyncIterator()
      _ = await iterator.next()
      closing.cancel()
      await #expect(throws: CancellationError.self) { try await closing.value }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test func partialRefusalRetainsMetadata() async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(RawRefusal()) }
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      do {
        _ = try await WebSocketConnector.live.connect(.init(url: url))
        Issue.record("unexpected acceptance")
      } catch WebSocketError.refused(let status, let headers, let body) {
        #expect(status == 429)
        #expect(headers[.retryAfter] == "7")
        #expect(body == Array("partial".utf8))
      } catch { Issue.record("refusal metadata lost: \(error)") }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }

  @Test(arguments: ["sec-websocket-protocol", "sec-websocket-extensions"])
  func unsolicitedNegotiationIsRejected(header: String) async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { channel, _ in
          channel.eventLoop.makeSucceededFuture(HTTPHeaders([(header, "unsolicited")]))
        }, upgradePipelineHandler: { channel, _ in
          channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: [3, 232])), promise: nil)
          return channel.eventLoop.makeSucceededVoidFuture()
        })
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
      }.bind(host: "127.0.0.1", port: 0).get()
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.localAddress?.port))/")!
      do {
        let connection = try await WebSocketConnector.live.connect(.init(url: url))
        connection.abort()
        Issue.record("accepted unrequested \(header)")
      } catch WebSocketError.protocolViolation {} catch { Issue.record("unexpected error: \(error)") }
      try await server.close().get()
    } catch { try? await server.close().get(); throw error }
  }
}

private final class HoldClose: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  let signal: AsyncStream<Void>.Continuation
  init(signal: AsyncStream<Void>.Continuation) { self.signal = signal }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if unwrapInboundIn(data).opcode == .connectionClose { signal.yield(()) }
  }
}

private final class RawRefusal: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  private var sent = false
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !sent else { return }
    sent = true
    let channel = context.channel
    channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\nContent-Length: 100\r\n\r\npartial")).whenComplete { _ in channel.close(promise: nil) }
  }
}

private final class UnfinishedRefusal: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  private var sent = false
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !sent else { return }
    sent = true
    context.write(NIOAny(ByteBuffer(string: "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\n")), promise: nil)
    context.writeAndFlush(NIOAny(ByteBuffer(bytes: Array(repeating: UInt8(ascii: "x"), count: 1 << 20))), promise: nil)
  }
}

private final class RefusalThenClose: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  private let reset: Bool
  private var sent = false
  init(reset: Bool) { self.reset = reset }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !sent else { return }
    sent = true
    let length = reset ? 4 : 10
    let body = reset ? "nope" : ""
    let response = ByteBuffer(string: "HTTP/1.1 502 Bad Gateway\r\nX-Refusal: kept\r\nContent-Length: \(length)\r\n\r\n\(body)")
    let channel = context.channel
    channel.writeAndFlush(response).whenComplete { _ in channel.close(promise: nil) }
  }
}
