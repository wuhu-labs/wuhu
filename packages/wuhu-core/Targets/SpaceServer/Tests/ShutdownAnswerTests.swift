#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import Serve
import ServeNIO
import ServeTLS
@testable import SpaceServer
import Synchronization
import Testing

/// The handler a live server serves through: `HostRequests` re-serves every
/// response body through its own accounting, so a shutdown has to see the
/// wrapped body as the plain response it is and let it finish. A buffered
/// body classified as a stream is cut off here.
@Suite(.serialized)
struct ShutdownAnswerTests {
  @Test func aRunningRequestAnswersThroughTheHostWrapperThenHTTP2GoAways() async throws {
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
    let requests = HostRequests()
    let sockets = HostSockets()
    let hosted = spaceOwnedHandler(
      handler: { _ in
        startedContinuation.yield()
        for await _ in release { break }
        return .response(try Response.json(JSONValue.object(["answer": .string("answered")])))
      },
      requests: requests,
      sockets: sockets,
    )
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity, upgrading: hosted)

    do {
      let port = try #require(server.boundAddress.port)
      let connection = try await H2Connection.open(port: port)
      do {
        try await connection.request(path: "/slow")
        try await bounded(seconds: 5) {
          for await _ in started { break }
        }
        let stopping = Task { await server.shutdown() }
        let errorCode = try await bounded(seconds: 5) { await connection.goAway() }
        #expect(errorCode == .noError)
        releaseContinuation.yield()
        let response = try await connection.waitForResponse(seconds: 5)
        #expect(response.status == 200)
        #expect(response.body?.contains("answered") == true)
        await stopping.value
      } catch {
        await connection.close()
        throw error
      }
      await connection.close()
    } catch {
      await server.shutdown()
      await requests.shutdown(sockets: sockets)
      throw error
    }

    await server.shutdown()
    await requests.shutdown(sockets: sockets)
  }
}

private struct H2Response: Sendable {
  var status: Int?
  var body: String?
}

private final class H2Connection: Sendable {
  private let channel: Channel
  private let stream: Channel
  private let goAways: AsyncStream<HTTP2ErrorCode>
  private let responses: HTTP2ResponseParts

  private init(channel: Channel, stream: Channel, goAways: AsyncStream<HTTP2ErrorCode>, responses: HTTP2ResponseParts) {
    self.channel = channel
    self.stream = stream
    self.goAways = goAways
    self.responses = responses
  }

  static func open(port: Int) async throws -> Self {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    tls.applicationProtocols = ["h2"]
    let sslContext = try NIOSSLContext(configuration: tls)
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: "localhost"))
        }
      }
      .connect(host: "127.0.0.1", port: port)
      .get()
    let multiplexer = try await channel.configureHTTP2Pipeline(mode: .client) { stream in
      stream.eventLoop.makeSucceededVoidFuture()
    }.get()
    let (goAways, goAwayContinuation) = AsyncStream<HTTP2ErrorCode>.makeStream()
    try await channel.pipeline.addHandler(GoAwayRecorder(continuation: goAwayContinuation))
    let responses = HTTP2ResponseParts()
    let stream = try await multiplexer.createStreamChannel { stream in
      stream.eventLoop.makeCompletedFuture {
        try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
        try stream.pipeline.syncOperations.addHandler(responses)
      }
    }.get()
    return Self(channel: channel, stream: stream, goAways: goAways, responses: responses)
  }

  func request(path: String) async throws {
    let head = HTTPRequestHead(version: .http2, method: .GET, uri: path, headers: ["host": "localhost"])
    try await self.stream.writeAndFlush(HTTPClientRequestPart.head(head))
    try await self.stream.writeAndFlush(HTTPClientRequestPart.end(nil))
  }

  func goAway() async -> HTTP2ErrorCode? {
    for await errorCode in self.goAways { return errorCode }
    return nil
  }

  func waitForResponse(seconds: Double) async throws -> H2Response {
    let deadline = ContinuousClock.now + .milliseconds(Int64(seconds * 1000))
    while ContinuousClock.now < deadline {
      if self.responses.isEnded { return self.responses.snapshot() }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ShutdownTimeout.timedOut
  }

  func close() async {
    try? await self.stream.close()
    try? await self.channel.close()
  }
}

private final class GoAwayRecorder: ChannelInboundHandler, Sendable {
  typealias InboundIn = HTTP2Frame

  private let continuation: AsyncStream<HTTP2ErrorCode>.Continuation

  init(continuation: AsyncStream<HTTP2ErrorCode>.Continuation) {
    self.continuation = continuation
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case let .goAway(_, errorCode, _) = self.unwrapInboundIn(data).payload {
      self.continuation.yield(errorCode)
    }
    context.fireChannelRead(data)
  }
}

private final class HTTP2ResponseParts: ChannelInboundHandler, Sendable {
  typealias InboundIn = HTTPClientResponsePart

  private struct State {
    var status: Int?
    var body = ""
    var ended = false
  }

  private let state = Mutex(State())

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let part = self.unwrapInboundIn(data)
    self.state.withLock { state in
      switch part {
      case let .head(head):
        state.status = Int(head.status.code)
      case let .body(buffer):
        state.body += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
      case .end:
        state.ended = true
      }
    }
    context.fireChannelRead(data)
  }

  var isEnded: Bool {
    self.state.withLock { $0.ended }
  }

  func snapshot() -> H2Response {
    self.state.withLock { H2Response(status: $0.status, body: $0.body) }
  }
}

private enum ShutdownTimeout: Error {
  case timedOut
}

private func bounded<T: Sendable>(
  seconds: Double,
  _ operation: @escaping @Sendable () async -> T,
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw ShutdownTimeout.timedOut
    }
    let value = try await group.next()
    group.cancelAll()
    return try #require(value)
  }
}
