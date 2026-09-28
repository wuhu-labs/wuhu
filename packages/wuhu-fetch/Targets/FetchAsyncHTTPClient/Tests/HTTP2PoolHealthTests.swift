import AsyncHTTPClient
import FetchAsyncHTTPClient
import NIOCore
import NIOHTTP2
import NIOPosix
import NIOSSL
import Synchronization
import Testing

@Suite struct HTTP2PoolHealthTests {
  @Test(arguments: [true, false])
  func onlyAnUnresponsiveParentIsEvicted(dropsAcknowledgements: Bool) async throws {
    let accepted = Mutex(0)
    let requests = Mutex(0)
    let tls = try healthTestTLSContext()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        accepted.withLock { $0 += 1 }
        let completion = channel.eventLoop.makePromise(of: Void.self)
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
        }.flatMap {
          channel.configureHTTP2Pipeline(mode: .server) { stream in
            let stall = requests.withLock { count in
              count += 1
              return count == 1
            }
            return stream.eventLoop.makeCompletedFuture {
              try stream.pipeline.syncOperations.addHandler(HealthTestResponse(stall: stall, completion: completion.futureResult))
            }
          }.flatMapThrowing { _ in
            try channel.pipeline.syncOperations.addHandler(CompleteAfterTwoPings(completion: completion))
          }
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()

    let initialized = Mutex(0)
    var configuration = HTTPClient.Configuration()
    configuration.tlsConfiguration = .makeClientConfiguration()
    configuration.tlsConfiguration?.certificateVerification = .none
    configuration.http2ConnectionDebugInitializer = { channel in
      let drop = initialized.withLock { count in
        count += 1
        return count == 1 && dropsAcknowledgements
      }
      return channel.eventLoop.makeCompletedFuture {
        if drop {
          let codec = try channel.pipeline.syncOperations.handler(type: NIOHTTP2Handler.self)
          try channel.pipeline.syncOperations.addHandler(DropHealthPings(), position: .after(codec))
        }
      }
    }
    configuration.enableHTTP2HealthChecks(idleInterval: .milliseconds(100), acknowledgementTimeout: .seconds(2))
    let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    do {
      let port = try #require(server.localAddress?.port)
      let request = HTTPClientRequest(url: "https://localhost:\(port)/")
      let stalled = try await client.execute(request, timeout: .seconds(10))
      #expect(stalled.version == .http2)
      #expect(stalled.status.code == 200)
      if dropsAcknowledgements {
        await #expect(throws: HTTPClientError.remoteConnectionClosed) {
          _ = try await stalled.body.collect(upTo: 1024)
        }
      } else {
        _ = try await stalled.body.collect(upTo: 1024)
      }
      let response = try await client.execute(request, timeout: .seconds(10))
      #expect(response.version == .http2)
      #expect(response.status.code == 204)
      _ = try await response.body.collect(upTo: 1024)
      #expect(initialized.withLock { $0 } == (dropsAcknowledgements ? 2 : 1))
      #expect(accepted.withLock { $0 } == (dropsAcknowledgements ? 2 : 1))
      try await client.shutdown()
      try await server.close().get()
    } catch {
      try? await client.shutdown()
      try? await server.close().get()
      throw error
    }
  }
}

private final class DropHealthPings: ChannelOutboundHandler {
  typealias OutboundIn = HTTP2Frame

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    if case .ping = unwrapOutboundIn(data).payload {
      promise?.succeed(())
    } else {
      context.write(data, promise: promise)
    }
  }
}

private final class HealthTestResponse: ChannelInboundHandler {
  typealias InboundIn = HTTP2Frame.FramePayload
  typealias OutboundOut = HTTP2Frame.FramePayload
  let stall: Bool
  let completion: EventLoopFuture<Void>

  init(stall: Bool, completion: EventLoopFuture<Void>) {
    self.stall = stall
    self.completion = completion
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .headers = unwrapInboundIn(data) else { return }
    let response = HTTP2Frame.FramePayload.headers(.init(
      headers: [":status": stall ? "200" : "204"], endStream: !stall,
    ))
    context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    if stall {
      let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
      completion.whenSuccess {
        let context = bound.value
        let end = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(context.channel.allocator.buffer(capacity: 0)), endStream: true))
        context.writeAndFlush(NIOAny(end), promise: nil)
      }
    }
  }
}

private final class CompleteAfterTwoPings: ChannelInboundHandler {
  typealias InboundIn = HTTP2Frame
  private var remaining = 2
  private var completion: EventLoopPromise<Void>?

  init(completion: EventLoopPromise<Void>) { self.completion = completion }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if case .ping(_, ack: false) = unwrapInboundIn(data).payload {
      remaining -= 1
      if remaining == 0 {
        completion?.succeed(())
        completion = nil
      }
    }
    context.fireChannelRead(data)
  }

  func channelInactive(context: ChannelHandlerContext) {
    completion?.fail(ChannelError.ioOnClosedChannel)
    completion = nil
    context.fireChannelInactive()
  }
}

private func healthTestTLSContext() throws -> NIOSSLContext {
  let certificate = """
  -----BEGIN CERTIFICATE-----
  MIIBfjCCASWgAwIBAgIUdQp74ESS6+cjJKZATuHu0dGGC1QwCgYIKoZIzj0EAwIw
  FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDkxNzA3MTAwMFoYDzIxMjYwODI0
  MDcxMDAwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
  PQMBBwNCAAQTG2/8i1+6M+xG72R8s55FX7NWisHjgOSRWCKvAaXJo9FNRAay143O
  n2BUZBGy6KGj4u3S9ubS4gt1bfHHdhCUo1MwUTAdBgNVHQ4EFgQU4rOuAedt0Gm4
  ukgGhv96QsqYf+EwHwYDVR0jBBgwFoAU4rOuAedt0Gm4ukgGhv96QsqYf+EwDwYD
  VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAQqTwQiXYcCzSaUlD2prBi
  z3IyfmJlDqclnk1A9XfsbwIgQPi24r+gjnTdwvPRqCvZo1k1Hqsxhyxmj13k4s1D
  cUI=
  -----END CERTIFICATE-----
  """
  let key = """
  -----BEGIN PRIVATE KEY-----
  MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgU3eX7t3QFjZUP2gH
  ddhPHi3alIUzPjHYr5+w61aTk4ShRANCAAQTG2/8i1+6M+xG72R8s55FX7NWisHj
  gOSRWCKvAaXJo9FNRAay143On2BUZBGy6KGj4u3S9ubS4gt1bfHHdhCU
  -----END PRIVATE KEY-----
  """
  var configuration = TLSConfiguration.makeServerConfiguration(
    certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(certificate.utf8), format: .pem))],
    privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem)),
  )
  configuration.applicationProtocols = ["h2"]
  return try NIOSSLContext(configuration: configuration)
}
