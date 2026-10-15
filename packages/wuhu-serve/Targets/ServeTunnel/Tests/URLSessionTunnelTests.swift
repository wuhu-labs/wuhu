import Fetch
import FetchTunnel
@testable import FetchTunnelURLSession
import Foundation
import Serve
import ServeNIO
import ServeTunnel
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct URLSessionTunnelTests {
  @Test func appleAdapterNegotiatesAndServesFetch() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .boundedWebSocket(limits: .init(), subprotocol: TunnelTransport.webSocketSubprotocol) { transport in
        try? await ServeTunnel.run(handler: { _ in .text("phone-compatible") }, over: transport)
      }
    })
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.boundAddress.port))/")!
      let transport = try await TunnelURLSession.connect(url: url, session: session, limits: .init(messageBytes: 64 << 10))
      #expect(transport.maxMessageBytes == 64 << 10)
      #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(chunkBytes: 64 << 10)) }
      let tunnel = try Tunnel(over: transport)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try? await tunnel.run() }
        let response = try await tunnel.client(Request(url: URL(string: "https://example.test/query")!))
        #expect(try await response.body.text() == "phone-compatible")
        await tunnel.abort()
        group.cancelAll()
      }
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  @Test func missingSelectionNeverBecomesTunnelTraffic() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .webSocket { socket in for await _ in socket.inbound {} }
    })
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    do {
      let url = URL(string: "ws://127.0.0.1:\(try #require(server.boundAddress.port))/")!
      await #expect(throws: TunnelError.unsupportedSubprotocol) { try await TunnelURLSession.connect(url: url, session: session) }
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  // Cancelling while the ping is pending fails its pong handler; a reset during the socket's teardown fails it again.
  // A message the peer sent first holds the pong back, so the ping is still pending at cancellation.
  // On the macOS pool the second call arrived in about 5 of 8 attempts, so 16 attempts all miss it with odds below
  // one in a million. A single attempt passes about 40% of the time on the old continuation; keep the count.
  @Test(arguments: 0 ..< 16) func cancellingWhilePingIsPendingFailsOnce(_ attempt: Int) async throws {
    let peer = try RawWebSocketPeer()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(peer.port)/")!
    let dial = Task { try await TunnelURLSession.connect(url: url, session: session) }
    await peer.serve(.message)
    dial.cancel()
    peer.reset()
    await #expect(throws: (any Error).self) { try await dial.value }
    // Leave room for URLSession's second pong-handler call.
    try await Task.sleep(for: .milliseconds(300))
  }

  // After a close frame URLSession never calls the ping's pong handler, so only cancellation can end the dial.
  @Test func cancellingADialWhosePingNeverSettlesThrowsCancellation() async throws {
    let peer = try RawWebSocketPeer()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(peer.port)/")!
    let dial = Task { try await TunnelURLSession.connect(url: url, session: session) }
    await peer.serve(.closeFrame)
    let cancelled = ContinuousClock.now
    dial.cancel()
    await #expect(throws: CancellationError.self) { try await dial.value }
    #expect(ContinuousClock.now - cancelled < .seconds(5))
    peer.reset()
  }

  @Test func firstPongOutcomeWinsAndLaterCallsAreDropped() async throws {
    try await firstPong { pong in
      pong(nil)
      pong(POSIXError(.ECONNABORTED))
    }

    let failure = await #expect(throws: POSIXError.self) {
      try await firstPong { pong in
        pong(POSIXError(.ECONNABORTED))
        pong(POSIXError(.ECONNABORTED))
        pong(nil)
      }
    }
    #expect(failure?.code == .ECONNABORTED)

    // A call that arrives after the waiter has returned.
    let held = HeldPong()
    try await firstPong { pong in
      held.store(pong)
      pong(nil)
    }
    held.call(POSIXError(.ECONNABORTED))
    held.call(nil)
  }
}

private final class HeldPong: @unchecked Sendable {
  private let lock = NSLock()
  private var pong: (@Sendable ((any Error)?) -> Void)?
  func store(_ pong: @escaping @Sendable ((any Error)?) -> Void) { lock.withLock { self.pong = pong } }
  func call(_ error: (any Error)?) { lock.withLock { pong }?(error) }
}
