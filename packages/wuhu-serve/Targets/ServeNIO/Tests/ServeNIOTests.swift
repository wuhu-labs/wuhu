#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import NIOCore
import NIOPosix
import Serve
import ServeNIO
import Synchronization
import Testing

@Suite(.serialized)
struct ServeNIOTests {
  @Test func bindsOnPortZeroExposesAssignedPortAndServesOverTCP() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { request in
      let body = try await bodyText(request.body) ?? ""
      return Response(
        status: .ok,
        body: .chunk(Data("\(request.method.rawValue) \(request.url.path) \(body)".utf8)),
      )
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      #expect(port > 0)
      #expect(recorder.snapshot().didBindAddresses == [String(describing: server.boundAddress)])

      try await withHTTPClient { client in
        let request = Request(
          url: try #require(URL(string: "http://127.0.0.1:\(port)/echo")),
          method: .post,
          body: .chunks(
            [
              Data("hello".utf8),
              Data(" world".utf8),
            ],
            contentType: "text/plain",
          ),
        )

        let response = try await FetchClient.asyncHTTPClient(client)(request).validateStatus()
        #expect(try await response.text() == "POST /echo hello world")
      }
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
    #expect(snapshot.acceptedConnectionCount == 1)
    #expect(snapshot.startupFailures.isEmpty)
    #expect(snapshot.connectionErrors.isEmpty)
    #expect(snapshot.handlerErrors.isEmpty)
  }

  @Test func bindsWildcardHostReachableViaLoopback() async throws {
    try await withTCPServer(host: "0.0.0.0") { request in
      Response(status: .ok, body: .chunk(Data("bound \(request.url.path)".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withHTTPClient { client in
        let request = Request(
          url: try #require(URL(string: "http://127.0.0.1:\(port)/lan")),
          method: .get,
        )
        let response = try await FetchClient.asyncHTTPClient(client)(request).validateStatus()
        #expect(try await response.text() == "bound /lan")
      }
    }
  }

  @Test func reportsStartupFailureThroughHooks() async throws {
    let firstServer = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0) { _ in
      Response(status: .ok, body: .chunk(Data("ok".utf8)))
    }

    do {
      let port = try #require(firstServer.boundAddress.port)
      let recorder = HookRecorder()

      var didThrow = false
      do {
        let secondServer = try await ServeNIOServer.bind(
          host: "127.0.0.1",
          port: port,
          hooks: recorder.hooks,
        ) { _ in
          Response(status: .ok, body: .chunk(Data("ok".utf8)))
        }
        await secondServer.shutdown()
      } catch {
        didThrow = true
      }

      #expect(didThrow)
      #expect(recorder.snapshot().startupFailures.count == 1)
      #expect(recorder.snapshot().didBindAddresses.isEmpty)
    } catch {
      await firstServer.shutdown()
      throw error
    }

    await firstServer.shutdown()
  }

  @Test func runUntilCancelledShutsTheServerDown() async throws {
    let recorder = HookRecorder()
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, hooks: recorder.hooks) { _ in
      Response(status: .ok, body: .chunk(Data("ok".utf8)))
    }

    let port = try #require(server.boundAddress.port)
    let task = Task {
      await server.runUntilCancelled()
    }

    await Task.yield()
    task.cancel()
    await task.value

    await expectTCPConnectionFailure(port: port)

    let snapshot = recorder.snapshot()
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
  }

  @Test func shutdownTerminatesActiveStreamingConnections() async throws {
    let recorder = HookRecorder()
    let controller = StreamingBodyController()
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, hooks: recorder.hooks) { _ in
      Response(
        status: .ok,
        body: .stream(contentType: "text/plain; charset=utf-8", controller.stream),
      )
    }

    let startedPromise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
    let inactivePromise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)

    do {
      let port = try #require(server.boundAddress.port)
      let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelInitializer { channel in
          channel.pipeline.addHandler(
            StreamingResponseObserver(
              startedPromise: startedPromise,
              inactivePromise: inactivePromise,
              needle: "tick",
            ),
          )
        }
        .connect(host: "127.0.0.1", port: port)
        .get()

      let request = rawRequest(path: "/stream")
      try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))

      _ = try await withTimeout(seconds: 5) {
        try await startedPromise.futureResult.get()
      }

      async let shutdown: Void = server.shutdown()
      let finalResponse = try await withTimeout(seconds: 5) {
        try await inactivePromise.futureResult.get()
      }
      await shutdown
      controller.finish()

      #expect(finalResponse.contains("HTTP/1.1 200 OK\r\n"))
      #expect(finalResponse.contains("tick"))
    } catch {
      controller.finish()
      await server.shutdown()
      throw error
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
    #expect(snapshot.acceptedConnectionCount == 1)
  }

  @Test func reportsHandlerThrownErrorsWithoutSwallowingThem() async throws {
    enum HandlerFailure: Error {
      case boom
    }

    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { _ in
      throw HandlerFailure.boom
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(port: port, request: rawRequest(path: "/boom"))
      #expect(response.contains("HTTP/1.1 500 Internal Server Error\r\n"))
      #expect(response.contains("500 Internal Server Error\n"))
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.handlerErrors.count == 1)
    #expect(snapshot.handlerErrors[0].contains("boom"))
    #expect(snapshot.connectionErrors.isEmpty)
  }

  @Test func streamedResponseFailureAfterHeadersClosesConnectionWithoutSecondResponse() async throws {
    enum StreamFailure: Error {
      case boom
    }

    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { _ in
      Response(
        status: .ok,
        body: .stream(
          contentType: "text/plain; charset=utf-8",
          AsyncThrowingStream { continuation in
            continuation.yield(Data("hello".utf8))
            continuation.finish(throwing: StreamFailure.boom)
          },
        ),
      )
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(port: port, request: rawRequest(path: "/stream"))
      #expect(response.contains("HTTP/1.1 200 OK\r\n"))
      #expect(response.contains("transfer-encoding: chunked\r\n"))
      #expect(response.contains("5\r\nhello\r\n"))
      #expect(!response.contains("HTTP/1.1 500 Internal Server Error\r\n"))
      #expect(!response.contains("500 Internal Server Error\n"))
      #expect(!response.hasSuffix("0\r\n\r\n"))
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.connectionErrors.count == 1)
    #expect(snapshot.connectionErrors[0].contains("boom"))
    #expect(snapshot.handlerErrors.isEmpty)
  }

  @Test func malformedRequestsDoNotCrashTheServer() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { _ in
      Response(status: .ok, body: .chunk(Data("ok".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let malformedResponse = try await sendRawTCPRequest(
        port: port,
        request: Data("GET / HTTP/1.1\r\n\r\n".utf8),
      )
      #expect(malformedResponse.contains("HTTP/1.1 400 Bad Request\r\n"))

      try await withHTTPClient { client in
        let request = Request(url: try #require(URL(string: "http://127.0.0.1:\(port)/health")))
        let response = try await FetchClient.asyncHTTPClient(client)(request).validateStatus()
        #expect(try await response.text() == "ok")
      }
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.connectionErrors.isEmpty)
    #expect(snapshot.handlerErrors.isEmpty)
  }

  @Test func serveErrorsThrownByHandlersUseServeStatusAndSkipHandlerErrorHook() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { request in
      try request.requireNoBody()
      return Response(status: .ok)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(
        port: port,
        request: rawRequest(path: "/no-body", method: .post, body: "unexpected"),
      )
      #expect(response.contains("HTTP/1.1 400 Bad Request\r\n"))
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.handlerErrors.isEmpty)
    #expect(snapshot.connectionErrors.isEmpty)
  }

  @Test func earlyResponseWithUnconsumedRequestBodyKeepsHandlerStatus() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { _ in
      Response(status: .unauthorized)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(
        port: port,
        request: rawRequest(path: "/v1/tools/read", method: .post, body: #"{"path":"/a.md"}"#),
      )
      #expect(response.contains("HTTP/1.1 401"))
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.handlerErrors.isEmpty)
    #expect(snapshot.connectionErrors.isEmpty)
  }

  @Test func requestBodyLimitSurfacedWhileHandlerReadsUsesServeStatus() async throws {
    let recorder = HookRecorder()
    let options = ServeOptions(maximumBodyBytes: 4)

    try await withTCPServer(options: options, hooks: recorder.hooks) { request in
      _ = try await request.body?.bytes()
      return Response(status: .ok)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(
        port: port,
        request: rawRequest(path: "/limit", method: .post, body: "too large"),
      )
      #expect(response.contains("HTTP/1.1 413"))
    }

    let snapshot = recorder.snapshot()
    #expect(snapshot.handlerErrors.isEmpty)
  }

  @Test func requestHeadLimitsReturnHeaderFieldsTooLarge() async throws {
    let options = ServeOptions(maximumHeadBytes: 1024, maximumHeaderLineBytes: 8)

    try await withTCPServer(options: options) { _ in
      Response(status: .ok)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(port: port, request: rawRequest(path: "/limit"))
      #expect(response.contains("HTTP/1.1 431 Request Header Fields Too Large\r\n"))
    }
  }

  @Test func totalRequestHeadLimitReturnsHeaderFieldsTooLarge() async throws {
    let options = ServeOptions(maximumHeadBytes: 24, maximumHeaderLineBytes: 1024)

    try await withTCPServer(options: options) { _ in
      Response(status: .ok)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let response = try await sendRawTCPRequest(port: port, request: rawRequest(path: "/limit"))
      #expect(response.contains("HTTP/1.1 431 Request Header Fields Too Large\r\n"))
    }
  }

  @Test func unixDomainSocketLifecycleWorks() async throws {
    let socketPath = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sock")
      .path

    let recorder = HookRecorder()

    do {
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: socketPath, hooks: recorder.hooks) {
        request in
        let body = try await bodyText(request.body) ?? ""
        return Response(
          status: .ok,
          body: .chunk(Data("\(request.method.rawValue) \(request.url.path) \(body)".utf8)),
        )
      }

      do {
        let response = try await sendRawUnixDomainSocketRequest(
          socketPath: socketPath,
          request: rawRequest(path: "/echo", method: .post, body: "hello world"),
        )
        #expect(response.contains("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("POST /echo hello world"))
        #expect(String(describing: server.boundAddress).contains(socketPath))
      } catch {
        await server.shutdown()
        throw error
      }

      await server.shutdown()
    } catch {
      try? FileManager.default.removeItem(atPath: socketPath)
      throw error
    }

    try? FileManager.default.removeItem(atPath: socketPath)

    let snapshot = recorder.snapshot()
    #expect(snapshot.didBindAddresses.count == 1)
    #expect(snapshot.willShutdownAddresses.count == 1)
    #expect(snapshot.didShutdownAddresses.count == 1)
    #expect(snapshot.acceptedConnectionCount == 1)
  }

  @Test func keepAliveServesTwoRequestsOnOneReusedConnection() async throws {
    let recorder = HookRecorder()

    try await withTCPServer(hooks: recorder.hooks) { request in
      Response(status: .ok, body: .chunk(Data("echo \(request.url.path)".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: rawRequest(path: "/one", keepAlive: true)))
        try await waitUntil { accumulator.text.contains("echo /one") }
        #expect(!accumulator.isInactive)

        try await channel.writeAndFlush(channel.allocator.buffer(bytes: rawRequest(path: "/two", keepAlive: true)))
        try await waitUntil { accumulator.text.contains("echo /two") }

        #expect(!accumulator.isInactive)
        #expect(!accumulator.text.lowercased().contains("connection: close"))
      }
    }

    // A single accepted connection served both requests.
    #expect(recorder.snapshot().acceptedConnectionCount == 1)
  }

  @Test func connectionCloseHeaderClosesAfterResponse() async throws {
    try await withTCPServer { _ in
      Response(status: .ok, body: .chunk(Data("bye".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: rawRequest(path: "/x", keepAlive: false)))
        try await waitUntil { accumulator.isInactive }
        #expect(accumulator.text.lowercased().contains("connection: close"))
        #expect(accumulator.text.contains("bye"))
      }
    }
  }

  @Test func http10RequestClosesConnectionAfterResponse() async throws {
    try await withTCPServer { _ in
      Response(status: .ok, body: .chunk(Data("v10".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        let request = Data("GET /legacy HTTP/1.0\r\nHost: local\r\n\r\n".utf8)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))
        try await waitUntil { accumulator.isInactive }
        #expect(accumulator.text.contains("v10"))
      }
    }
  }

  @Test func pipelinedRequestsAreAnsweredInOrder() async throws {
    try await withTCPServer { request in
      Response(status: .ok, body: .chunk(Data("<\(request.url.path)>".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        var burst = Data()
        burst += rawRequest(path: "/a", keepAlive: true)
        burst += rawRequest(path: "/b", keepAlive: true)
        burst += rawRequest(path: "/c", keepAlive: true)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: burst))

        try await waitUntil {
          let text = accumulator.text
          return text.contains("</a>") && text.contains("</b>") && text.contains("</c>")
        }

        let text = accumulator.text
        let indexA = try #require(text.range(of: "</a>")).lowerBound
        let indexB = try #require(text.range(of: "</b>")).lowerBound
        let indexC = try #require(text.range(of: "</c>")).lowerBound
        #expect(indexA < indexB)
        #expect(indexB < indexC)
      }
    }
  }

  @Test func keepAliveIdleTimeoutClosesParkedConnection() async throws {
    let options = ServeOptions(keepAliveIdleTimeout: .milliseconds(200), requestReadInactivityTimeout: nil)

    try await withTCPServer(options: options) { _ in
      Response(status: .ok, body: .chunk(Data("hi".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: rawRequest(path: "/keep", keepAlive: true)))
        try await waitUntil { accumulator.text.contains("hi") }
        #expect(!accumulator.isInactive)
        // The parked connection is reaped by the idle timeout without any further request.
        try await waitUntil(timeout: .seconds(3)) { accumulator.isInactive }
      }
    }
  }

  @Test func streamingResponseSurvivesReadTimeoutWhileClientSilent() async throws {
    let options = ServeOptions(keepAliveIdleTimeout: nil, requestReadInactivityTimeout: .milliseconds(150))
    let controller = StreamingBodyController()

    try await withTCPServer(options: options) { _ in
      Response(status: .ok, body: .stream(contentType: "text/plain; charset=utf-8", controller.stream))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: rawRequest(path: "/sse", keepAlive: true)))
        // Stay silent well past the read timeout; the in-flight stream must keep flowing.
        try await waitUntil(timeout: .seconds(3)) {
          accumulator.text.components(separatedBy: "tick").count > 4
        }
        #expect(!accumulator.isInactive)
      }
      controller.finish()
    }
  }

  @Test func backpressurePauseIsNotReapedByReadTimeout() async throws {
    // A short read-inactivity timeout with a consumer that stalls far longer
    // than it while the buffer is paused: the pause is our own doing, so the
    // healthy upload must survive and deliver in full.
    let options = ServeOptions(
      requestBodyHighWatermarkBytes: 4096,
      requestBodyLowWatermarkBytes: 1024,
      keepAliveIdleTimeout: nil,
      requestReadInactivityTimeout: .milliseconds(150),
    )
    let payloadSize = 64 * 1024

    try await withTCPServer(options: options) { request in
      var total = 0
      var stalledOnce = false
      for try await chunk in (request.body ?? .empty).asyncBytes() {
        total += chunk.count
        if !stalledOnce {
          stalledOnce = true
          // Hold the buffer full and paused well past the read timeout.
          try? await Task.sleep(nanoseconds: 600_000_000)
        }
      }
      return Response(status: .ok, body: .chunk(Data("received \(total)".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      let payload = String(repeating: "x", count: payloadSize)
      let response = try await sendRawTCPRequest(
        port: port,
        request: rawRequest(path: "/upload", method: .post, body: payload),
      )
      #expect(response.contains("received \(payloadSize)"))
    }
  }

  @Test func pipelinedStreamingResponseKeepsCorrectPhaseUnderShortTimeouts() async throws {
    // Regression for the pipelined phase clobber: request B is delivered
    // synchronously inside request A's response `.end` write, so its streaming
    // response must keep its awaiting-response phase and survive both the read
    // and idle timeouts despite write gaps longer than either.
    let options = ServeOptions(
      keepAliveIdleTimeout: .milliseconds(150),
      requestReadInactivityTimeout: .milliseconds(150),
    )
    let controller = StreamingBodyController(intervalNanoseconds: 250_000_000)

    try await withTCPServer(options: options) { request in
      if request.url.path == "/stream" {
        return Response(status: .ok, body: .stream(contentType: "text/plain; charset=utf-8", controller.stream))
      }
      return Response(status: .ok, body: .chunk(Data("first".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        var burst = Data()
        burst += rawRequest(path: "/first", keepAlive: true)
        burst += rawRequest(path: "/stream", keepAlive: true)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: burst))

        // The streaming (pipelined) response must survive several write gaps that
        // each exceed both timeouts.
        try await waitUntil(timeout: .seconds(5)) {
          accumulator.text.contains("first") && accumulator.text.components(separatedBy: "tick").count > 3
        }
        #expect(!accumulator.isInactive)
      }
      controller.finish()
    }
  }

  @Test func earlyResponseOnOversizedChunkedUploadClosesConnection() async throws {
    let options = ServeOptions(maximumBodyBytes: 8192, keepAliveIdleTimeout: nil, requestReadInactivityTimeout: nil)

    try await withTCPServer(options: options) { _ in
      // Respond immediately without consuming the (oversized) request body.
      Response(status: .unauthorized)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        var request = Data("POST /reject HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunk = String(repeating: "y", count: 16384)
        request += Data("\(String(chunk.count, radix: 16))\r\n\(chunk)\r\n0\r\n\r\n".utf8)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))

        // The undrained oversized body cannot be reused, so the connection closes.
        try await waitUntil(timeout: .seconds(3)) { accumulator.isInactive }
        #expect(accumulator.text.contains("HTTP/1.1 401"))
      }
    }
  }

  @Test func shutdownDrainsParkedKeepAliveConnection() async throws {
    // A connection parked between keep-alive requests (loop task awaiting the
    // next request) must let server shutdown complete, not hang draining.
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0) { _ in
      Response(status: .ok, body: .chunk(Data("ok".utf8)))
    }
    let port = try #require(server.boundAddress.port)
    do {
      try await withRawConnection(port: port) { channel, accumulator in
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: rawRequest(path: "/keep", keepAlive: true)))
        try await waitUntil { accumulator.text.contains("ok") }
        #expect(!accumulator.isInactive)
        // Shutdown must complete promptly; a hung loop task would time out here.
        try await withTimeout(seconds: 10) { await server.shutdown() }
      }
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func silentPreFirstHeadConnectionReapedByIdleTimeout() async throws {
    // Only the keep-alive idle timeout is configured; a client that connects and
    // sends nothing must still be reaped (generation 0, no head yet).
    let options = ServeOptions(keepAliveIdleTimeout: .milliseconds(200), requestReadInactivityTimeout: nil)

    try await withTCPServer(options: options) { _ in
      Response(status: .ok)
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { _, accumulator in
        try await waitUntil(timeout: .seconds(3)) { accumulator.isInactive }
      }
    }
  }

  @Test func pipelinedMalformedHeadAfterValidRequestIsIsolated() async throws {
    try await withTCPServer { request in
      Response(status: .ok, body: .chunk(Data("ok \(request.url.path)".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      try await withRawConnection(port: port) { channel, accumulator in
        var burst = Data(rawRequest(path: "/good", keepAlive: true))
        // A second head the parser rejects (no Host), pipelined behind the first.
        burst += Data("GET /bad HTTP/1.1\r\n\r\n".utf8)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: burst))

        try await waitUntil { accumulator.isInactive }
        let text = accumulator.text
        #expect(text.contains("ok /good"))
        #expect(text.contains("HTTP/1.1 400"))
        let goodIndex = try #require(text.range(of: "ok /good")).lowerBound
        let badIndex = try #require(text.range(of: "HTTP/1.1 400")).lowerBound
        #expect(goodIndex < badIndex)
      }
    }
  }

  @Test func oversizedDeclaredContentLengthRejectedAtHeadWith413() async throws {
    let options = ServeOptions(maximumBodyBytes: 1024)

    try await withTCPServer(options: options) { _ in
      Response(status: .ok, body: .chunk(Data("unreachable".utf8)))
    } operation: { server in
      let port = try #require(server.boundAddress.port)
      // A huge declared content-length must be rejected before any body is read.
      let request = Data("POST /big HTTP/1.1\r\nHost: local\r\nConnection: close\r\nContent-Length: 999999999\r\n\r\n".utf8)
      let response = try await sendRawTCPRequest(port: port, request: request)
      #expect(response.contains("HTTP/1.1 413"))
      #expect(!response.contains("unreachable"))
    }
  }
}

private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private var buffer = ByteBuffer()
  private let responsePromise: EventLoopPromise<String>

  init(responsePromise: EventLoopPromise<String>) {
    self.responsePromise = responsePromise
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    var data = self.unwrapInboundIn(data)
    self.buffer.writeBuffer(&data)
  }

  func channelInactive(context _: ChannelHandlerContext) {
    if let bytes = self.buffer.readBytes(length: self.buffer.readableBytes) {
      self.responsePromise.succeed(String(decoding: bytes, as: UTF8.self))
    } else {
      self.responsePromise.succeed("")
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.responsePromise.fail(error)
    context.close(promise: nil)
  }
}

private final class StreamingResponseObserver: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private var buffer = ByteBuffer()
  private var didObserveNeedle = false
  private let startedPromise: EventLoopPromise<String>
  private let inactivePromise: EventLoopPromise<String>
  private let needle: String

  init(
    startedPromise: EventLoopPromise<String>,
    inactivePromise: EventLoopPromise<String>,
    needle: String,
  ) {
    self.startedPromise = startedPromise
    self.inactivePromise = inactivePromise
    self.needle = needle
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    var data = self.unwrapInboundIn(data)
    self.buffer.writeBuffer(&data)

    guard !self.didObserveNeedle else {
      return
    }

    if let bytes = self.buffer.getBytes(at: 0, length: self.buffer.readableBytes) {
      let response = String(decoding: bytes, as: UTF8.self)
      if response.contains(self.needle) {
        self.didObserveNeedle = true
        self.startedPromise.succeed(response)
      }
    }
  }

  func channelInactive(context _: ChannelHandlerContext) {
    if let bytes = self.buffer.readBytes(length: self.buffer.readableBytes) {
      let response = String(decoding: bytes, as: UTF8.self)
      if !self.didObserveNeedle {
        self.startedPromise.succeed(response)
      }
      self.inactivePromise.succeed(response)
    } else {
      if !self.didObserveNeedle {
        self.startedPromise.succeed("")
      }
      self.inactivePromise.succeed("")
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.startedPromise.fail(error)
    self.inactivePromise.fail(error)
    context.close(promise: nil)
  }
}

private final class HookRecorder: @unchecked Sendable {
  struct Snapshot {
    var didBindAddresses: [String] = []
    var startupFailures: [String] = []
    var willShutdownAddresses: [String] = []
    var didShutdownAddresses: [String] = []
    var acceptedConnectionCount = 0
    var connectionErrors: [String] = []
    var handlerErrors: [String] = []
  }

  private var lock = pthread_mutex_t()
  private var storage = Snapshot()

  init() {
    pthread_mutex_init(&self.lock, nil)
  }

  deinit {
    pthread_mutex_destroy(&self.lock)
  }

  var hooks: ServeNIOHooks {
    ServeNIOHooks(
      onDidBind: { [weak self] address in
        self?.withLock {
          $0.didBindAddresses.append(String(describing: address))
        }
      },
      onStartupFailure: { [weak self] error in
        self?.withLock {
          $0.startupFailures.append(String(describing: error))
        }
      },
      onWillShutdown: { [weak self] address in
        self?.withLock {
          $0.willShutdownAddresses.append(String(describing: address))
        }
      },
      onDidShutdown: { [weak self] address in
        self?.withLock {
          $0.didShutdownAddresses.append(String(describing: address))
        }
      },
      onDidAcceptConnection: { [weak self] _ in
        self?.withLock {
          $0.acceptedConnectionCount += 1
        }
      },
      onConnectionError: { [weak self] _, error in
        self?.withLock {
          $0.connectionErrors.append(String(describing: error))
        }
      },
      onHandlerError: { [weak self] _, error in
        self?.withLock {
          $0.handlerErrors.append(String(describing: error))
        }
      },
    )
  }

  func snapshot() -> Snapshot {
    self.lockState()
    defer { self.unlockState() }
    return self.storage
  }

  private func withLock(_ update: (inout Snapshot) -> Void) {
    self.lockState()
    update(&self.storage)
    self.unlockState()
  }

  private func lockState() {
    pthread_mutex_lock(&self.lock)
  }

  private func unlockState() {
    pthread_mutex_unlock(&self.lock)
  }
}

private final class StreamingBodyController: @unchecked Sendable {
  let stream: AsyncStream<Data>

  private let continuation: AsyncStream<Data>.Continuation
  private let producerTask: Task<Void, Never>

  init(intervalNanoseconds: UInt64 = 50_000_000) {
    var capturedContinuation: AsyncStream<Data>.Continuation?
    self.stream = AsyncStream { continuation in
      capturedContinuation = continuation
    }
    let continuation = capturedContinuation!
    self.continuation = continuation

    self.producerTask = Task {
      continuation.yield(Data("tick\n".utf8))
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
        guard !Task.isCancelled else {
          break
        }
        continuation.yield(Data("tick\n".utf8))
      }
      continuation.finish()
    }
  }

  func finish() {
    self.producerTask.cancel()
    self.continuation.finish()
  }

  deinit {
    self.finish()
  }
}

private enum TimeoutError: Error {
  case timedOut(seconds: Double)
}

private func withTCPServer<T>(
  host: String = "127.0.0.1",
  port: Int = 0,
  options: ServeOptions = .init(),
  hooks: ServeNIOHooks = .init(),
  handler: @escaping Handler,
  operation: (ServeNIOServer) async throws -> T,
) async throws -> T {
  let server = try await ServeNIOServer.bind(
    host: host,
    port: port,
    options: options,
    hooks: hooks,
    handler: handler,
  )

  do {
    let value = try await operation(server)
    await server.shutdown()
    return value
  } catch {
    await server.shutdown()
    throw error
  }
}

private func withHTTPClient(
  _ operation: (HTTPClient) async throws -> Void,
) async throws {
  let client = HTTPClient(eventLoopGroupProvider: .singleton)
  do {
    try await operation(client)
    try await client.shutdown()
  } catch {
    try? await client.shutdown()
    throw error
  }
}

private func bodyText(_ body: Body?) async throws -> String? {
  guard let body else { return nil }
  return try await body.text()
}

private func sendRawTCPRequest(port: Int, request: Data) async throws -> String {
  let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { channel in
      channel.pipeline.addHandler(ResponseCollector(responsePromise: promise))
    }
    .connect(host: "127.0.0.1", port: port)
    .get()

  try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))
  return try await withTimeout(seconds: 5) {
    try await promise.futureResult.get()
  }
}

private func sendRawUnixDomainSocketRequest(
  socketPath: String,
  request: Data,
) async throws -> String {
  let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { channel in
      channel.pipeline.addHandler(ResponseCollector(responsePromise: promise))
    }
    .connect(unixDomainSocketPath: socketPath)
    .get()

  try await channel.writeAndFlush(channel.allocator.buffer(bytes: request))
  return try await withTimeout(seconds: 5) {
    try await promise.futureResult.get()
  }
}

private func rawRequest(
  path: String,
  method: Fetch.Method = .get,
  host: String = "local",
  body: String? = nil,
  keepAlive: Bool = false,
) -> Data {
  let body = body.map { Data($0.utf8) } ?? Data()
  var request = "\(method.rawValue) \(path) HTTP/1.1\r\n"
  request += "Host: \(host)\r\n"
  if !keepAlive {
    request += "Connection: close\r\n"
  }
  if !body.isEmpty {
    request += "Content-Length: \(body.count)\r\n"
  }
  request += "\r\n"
  return Data(request.utf8) + body
}

private func expectTCPConnectionFailure(port: Int) async {
  var didFail = false

  do {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connect(host: "127.0.0.1", port: port)
      .get()
    try? await channel.close()
  } catch {
    didFail = true
  }

  #expect(didFail)
}

private func withTimeout<T: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async throws -> T,
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TimeoutError.timedOut(seconds: seconds)
    }

    let value = try await group.next()
    group.cancelAll()
    return try #require(value)
  }
}

private final class ByteAccumulator: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer

  private struct State {
    var text = ""
    var inactive = false
  }

  private let state = Mutex(State())

  var text: String {
    self.state.withLock { $0.text }
  }

  var isInactive: Bool {
    self.state.withLock { $0.inactive }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = self.unwrapInboundIn(data)
    let chunk = buffer.readString(length: buffer.readableBytes) ?? ""
    self.state.withLock { $0.text += chunk }
    context.fireChannelRead(data)
  }

  func channelInactive(context: ChannelHandlerContext) {
    self.state.withLock { $0.inactive = true }
    context.fireChannelInactive()
  }
}

private func withRawConnection<T>(
  port: Int,
  _ body: (Channel, ByteAccumulator) async throws -> T,
) async throws -> T {
  let accumulator = ByteAccumulator()
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { channel in
      channel.pipeline.addHandler(accumulator)
    }
    .connect(host: "127.0.0.1", port: port)
    .get()

  do {
    let value = try await body(channel, accumulator)
    try? await channel.close()
    return value
  } catch {
    try? await channel.close()
    throw error
  }
}

private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @Sendable () -> Bool,
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  guard condition() else {
    throw TimeoutError.timedOut(seconds: 0)
  }
}
