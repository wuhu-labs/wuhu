#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import FetchWebSocket
import NIOCore
import NIOPosix
import NIOSSL
import enum PinnedTLS.PinnedTLS
import Serve
import ServeNIO
import ServeTLS
import Testing

@Suite(.serialized)
struct PinningTests {
  @Test func probeReturnsTheServedCertificate() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    try await withPinServer(identity: identity) { port in
      let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)
      #expect(try PinnedTLS.fingerprint(certificateDERBase64: observed) == (try identity.fingerprint()))
    }
  }

  @Test func pinnedClientConnectsWhenTheCertificateMatches() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    try await withPinServer(identity: identity) { port in
      let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)
      try await expectPinnedRoundTrip(port: port, fingerprint: try PinnedTLS.fingerprint(certificateDERBase64: observed))
    }
  }

  @Test func pinnedClientConnectsWhenTheLeafIsCASigned() async throws {
    let authority = try TLSIdentity.selfSigned(hosts: ["wuhu-test-ca"])
    let identity = try TLSIdentity.issued(hosts: ["localhost", "127.0.0.1"], by: authority)
    try await withPinServer(identity: identity) { port in
      let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)
      let fingerprint = try PinnedTLS.fingerprint(certificateDERBase64: observed)
      #expect(fingerprint == (try identity.fingerprint()))
      try await expectPinnedRoundTrip(port: port, fingerprint: fingerprint)
    }
  }

  @Test func pinnedFetchFramesABodilessPostOnTheRealWire() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity) { request in
      let framing = Serve.firstHeaderValue(named: "content-length", in: request.headers.fields) ?? "absent"
      return Response(status: .ok, body: .chunk(Data(framing.utf8)))
    }
    let port = try #require(server.boundAddress.port)
    let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)
    let fingerprint = try PinnedTLS.fingerprint(certificateDERBase64: observed)
    func framing(_ method: Fetch.Method) async throws -> String {
      let response = try await PinnedTLS.fetch(
        Request(url: URL(string: "https://127.0.0.1:\(port)/rotate")!, method: method),
        pinnedFingerprint: fingerprint,
        timeout: .seconds(10),
      )
      #expect(response.status == .ok)
      return try await response.body.text()
    }
    #expect(try await framing(.post) == "0")
    #expect(try await framing(.put) == "0")
    #expect(try await framing(.patch) == "0")
    #expect(try await framing(.get) == "absent")
    #expect(try await framing(.delete) == "absent")
    await server.shutdown()
  }

  @Test func pinnedFetchPreservesPercentEncodedRequestTargets() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    try await withPinServer(identity: identity) { port in
      let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)
      let response = try await PinnedTLS.fetch(
        Request(url: URL(string: "https://127.0.0.1:\(port)/pinned%20path%2Fseg?q=a%20b")!),
        pinnedFingerprint: try PinnedTLS.fingerprint(certificateDERBase64: observed),
        timeout: .seconds(10),
      )
      #expect(response.status == .ok)
      #expect(try await response.body.text() == "/pinned%20path%2Fseg")
    }
  }

  // Deterministic form of the early-response race: ServeNIO answers a
  // bodiless request on its head, so the server's close can beat the client's
  // trailing writes; the fetch must return the delivered response, not the
  // failed write.
  @Test func pinnedFetchReturnsAnEarlyResponseWhenTheServerClosesFirst() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let certificates = try NIOSSLCertificate.fromPEMBytes(Array(identity.certificatePEM.utf8))
    let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)
    var configuration = TLSConfiguration.makeServerConfiguration(
      certificateChain: certificates.map { .certificate($0) },
      privateKey: .privateKey(key),
    )
    configuration.applicationProtocols = ["http/1.1"]
    let context = try NIOSSLContext(configuration: configuration)
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let pipeline = channel.pipeline.syncOperations
          try pipeline.addHandler(NIOSSLServerHandler(context: context))
          try pipeline.addHandler(EarlyCloseResponder())
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()
    let port = try #require(server.localAddress?.port)

    var request = Request(url: URL(string: "https://127.0.0.1:\(port)/early")!, method: .post)
    request.body = .stream(AsyncStream(unfolding: { Data(repeating: 0, count: 1024) }))
    let response = try await PinnedTLS.fetch(
      request,
      pinnedFingerprint: try identity.fingerprint(),
      timeout: .seconds(10),
    )
    #expect(response.status == .ok)
    #expect(try await response.body.text() == "early")
    try? await server.close().get()
  }

  @Test func pinnedFetchCancellationClosesAStalledDial() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let (arrived, arrivedContinuation) = AsyncStream<Void>.makeStream()
    let (stall, stallContinuation) = AsyncStream<Void>.makeStream()
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity) { _ in
      arrivedContinuation.yield(())
      for await _ in stall {}
      return Response(status: .ok)
    }
    let port = try #require(server.boundAddress.port)
    let observed = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port)

    let dial = Task {
      _ = try await PinnedTLS.fetch(
        Request(url: URL(string: "https://127.0.0.1:\(port)/stall")!),
        pinnedFingerprint: try PinnedTLS.fingerprint(certificateDERBase64: observed),
        timeout: nil,
      )
    }
    var requests = arrived.makeAsyncIterator()
    _ = await requests.next()
    dial.cancel()
    await #expect(throws: CancellationError.self) {
      try await dial.value
    }
    stallContinuation.finish()
    await server.shutdown()
  }

  @Test func pinnedClientHardFailsOnADifferentCertificate() async throws {
    let served = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let pinned = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])

    try await withPinServer(identity: served) { port in
      let fingerprint = try pinned.fingerprint()

      await #expect(throws: (any Error).self) {
        _ = try await PinnedTLS.fetch(
          Request(url: URL(string: "https://127.0.0.1:\(port)/pinned")!),
          pinnedFingerprint: fingerprint,
          timeout: .seconds(10),
        )
      }

      await #expect(throws: (any Error).self) {
        _ = try await WebSocketClient.connect(
          url: URL(string: "wss://127.0.0.1:\(port)/ws")!,
          tls: .pinned(fingerprint: fingerprint),
        )
      }
    }
  }
}

private func expectPinnedRoundTrip(port: Int, fingerprint: String) async throws {
  let response = try await PinnedTLS.fetch(
    Request(url: URL(string: "https://127.0.0.1:\(port)/pinned")!),
    pinnedFingerprint: fingerprint,
    timeout: .seconds(10),
  )
  #expect(response.status == .ok)
  #expect(try await response.body.text() == "/pinned")

  let socket = try await WebSocketClient.connect(
    url: URL(string: "wss://127.0.0.1:\(port)/ws")!,
    tls: .pinned(fingerprint: fingerprint),
  )
  socket.close()
}

private final class EarlyCloseResponder: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private var responded = false

  func channelRead(context: ChannelHandlerContext, data _: NIOAny) {
    guard !responded else { return }
    responded = true
    var buffer = context.channel.allocator.buffer(capacity: 128)
    buffer.writeString("HTTP/1.1 200 OK\r\ncontent-length: 5\r\nconnection: close\r\n\r\nearly")
    let channel = context.channel
    context.writeAndFlush(NIOAny(buffer)).whenComplete { _ in
      channel.close(promise: nil)
    }
  }
}

private func withPinServer(identity: TLSIdentity, _ operation: (Int) async throws -> Void) async throws {
  let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity, upgrading: { request in
    if Serve.isWebSocketUpgradeRequest(request) {
      return .webSocket { socket in
        for await _ in socket.inbound {}
        socket.close()
      }
    }
    return .response(Response(status: .ok, body: .chunk(Data(request.url.path(percentEncoded: true).utf8))))
  })
  do {
    try await operation(try #require(server.boundAddress.port))
    await server.shutdown()
  } catch {
    await server.shutdown()
    throw error
  }
}
