#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import NIOCore
import NIOPosix
import NIOSSL
import enum NIOTLS.TLSUserEvent
import enum PinnedTLS.PinnedTLS
import Serve
import ServeNIO
import ServeTLS
import Testing

@Suite struct SNITests {
  @Test func oneLabelUnderASubdomainKeyGetsItsIdentityAndEveryOtherNameTheBareOne() async throws {
    let authority = try TLSIdentity.selfSigned(hosts: ["wuhu-test-ca"])
    let bare = try TLSIdentity.issued(hosts: ["space.test"], by: authority)
    let wildcard = try TLSIdentity.issued(hosts: ["*.space.test"], by: authority)
    let server = try await ServeNIOServer.bind(
      host: "127.0.0.1", port: 0, tls: bare, subdomains: ["Space.Test": wildcard],
    ) { _ in Response(status: .ok) }
    let port = try #require(server.boundAddress.port)
    let bareLeaf = try bare.fingerprint()
    let wildcardLeaf = try wildcard.fingerprint()
    #expect(try await handshakeLeaf(port: port, serverName: nil) == bareLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "space.test") == bareLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "alice.space.test") == wildcardLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "Bob.SPACE.test") == wildcardLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "a.b.space.test") == bareLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "alice.other.test") == bareLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "alicespace.test") == bareLeaf)
    #expect(try await handshakeLeaf(port: port, serverName: "localhost") == bareLeaf)
    await server.shutdown()
  }

  @Test func noSubdomainsServesTheIdentityToEveryName() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["space.test"])
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity) { _ in Response(status: .ok) }
    let port = try #require(server.boundAddress.port)
    #expect(try await handshakeLeaf(port: port, serverName: "alice.space.test") == (try identity.fingerprint()))
    #expect(try await handshakeLeaf(port: port, serverName: nil) == (try identity.fingerprint()))
    await server.shutdown()
  }
}

/// The leaf a completed handshake presents under `serverName` (no SNI when
/// nil): completion proves the served key matches the served certificate.
private func handshakeLeaf(port: Int, serverName: String?) async throws -> String {
  var configuration = TLSConfiguration.makeClientConfiguration()
  configuration.certificateVerification = .none
  let context = try NIOSSLContext(configuration: configuration)
  let loop = MultiThreadedEventLoopGroup.singleton.next()
  let completed = loop.makePromise(of: Void.self)
  let channel = try await ClientBootstrap(group: loop).connect(host: "127.0.0.1", port: port) { channel in
    channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: serverName))
      try channel.pipeline.syncOperations.addHandler(HandshakeCompletion(completed))
      return channel
    }
  }
  do {
    try await completed.futureResult.get()
    let leaf = try #require(try await channel.nioSSL_peerCertificate().get())
    try? await channel.close()
    return try PinnedTLS.fingerprint(certificateDERBase64: Data(try leaf.toDERBytes()).base64EncodedString())
  } catch {
    try? await channel.close()
    throw error
  }
}

private final class HandshakeCompletion: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let promise: EventLoopPromise<Void>
  private var settled = false

  init(_ promise: EventLoopPromise<Void>) {
    self.promise = promise
  }

  /// A stalled handshake fails the test instead of hanging the target.
  func handlerAdded(context: ChannelHandlerContext) {
    context.eventLoop.assumeIsolated().scheduleTask(in: .seconds(15)) {
      self.settle(.failure(ChannelError.connectTimeout(.seconds(15))))
    }
  }

  private func settle(_ result: Result<Void, any Error>) {
    guard !settled else { return }
    settled = true
    promise.completeWith(result)
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls { settle(.success(())) }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    settle(.failure(error))
    context.fireErrorCaught(error)
  }

  func channelInactive(context: ChannelHandlerContext) {
    settle(.failure(ChannelError.eof))
    context.fireChannelInactive()
  }
}
