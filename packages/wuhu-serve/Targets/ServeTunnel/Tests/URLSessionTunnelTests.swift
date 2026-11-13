import Fetch
import FetchTunnel
@testable import FetchTunnelURLSession
import Foundation
import Serve
import ServeNIO
import ServeTunnel
import Synchronization
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
      let upgraded = Mutex(0)
      let socket = try await TunnelURLSession.connect(url: url, session: session, limits: .init(messageBytes: 64 << 10), upgraded: { upgraded.withLock { $0 += 1 } })
      #expect(upgraded.withLock { $0 } == 1)
      let transport = socket.transport
      #expect(transport.maxMessageBytes == 64 << 10)
      #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(chunkBytes: 64 << 10)) }
      let tunnel = try Tunnel(over: transport)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try? await tunnel.run() }
        let response = try await tunnel.client(Request(url: URL(string: "https://example.test/query")!))
        #expect(try await response.body.text() == "phone-compatible")
        try await socket.ping()
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

  @Test func binaryBeforeAnyPongDoesNotHoldConnect() async throws {
    let peer = try RawWebSocketPeer()
    defer { peer.reset() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(peer.port)/")!
    let dial = Task { try await TunnelURLSession.connect(url: url, session: session) }
    await peer.serve(.message)
    let socket = try await dial.value
    defer { socket.transport.abort() }
    #expect(try await socket.transport.receive() == Data([1, 2, 3]))
  }

  @Test func pingBeforeFirstReceiveFinishesWhenTheReceiveLoopStarts() async throws {
    let peer = try RawWebSocketPeer()
    defer { peer.reset() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(peer.port)/")!
    async let serving: Void = peer.serve(.messagesBeforePong)
    let socket = try await TunnelURLSession.connect(url: url, session: session)
    defer { socket.transport.abort() }
    let ping = Task { try await socket.ping() }
    defer { ping.cancel() }
    await serving
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { () async throws -> Void in
        #expect(try await socket.transport.receive() == Data([1, 2, 3]))
        #expect(try await socket.transport.receive() == Data([4, 5, 6]))
        _ = try? await socket.transport.receive()
      }
      try await ping.value
      socket.transport.abort()
      group.cancelAll()
    }
  }

  @Test func failedUpgradeEndsConnect() async throws {
    let peer = try RawWebSocketPeer()
    defer { peer.reset() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(peer.port)/")!
    let dial = Task { try await TunnelURLSession.connect(url: url, session: session) }
    await peer.serve(.refuseUpgrade)
    await #expect(throws: (any Error).self) { try await dial.value }
  }

  @Test func cancellingBeforeUpgradeThrowsCancellation() async throws {
    let peer = try RawWebSocketPeer()
    defer { peer.reset() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "ws://127.0.0.1:\(peer.port)/")!
    let dial = Task { try await TunnelURLSession.connect(url: url, session: session) }
    await peer.serve(.holdUpgrade)
    dial.cancel()
    await #expect(throws: CancellationError.self) { try await dial.value }
  }

  @Test func cancellingAFirstPongWaitThrowsCancellationWithoutAnOutcome() async throws {
    let held = HeldPong()
    let (sent, sending) = AsyncStream<Void>.makeStream()
    let ping = Task {
      try await firstPong { pong in
        held.store(pong)
        sending.yield()
      }
    }
    defer { ping.cancel() }
    var pings = sent.makeAsyncIterator()
    _ = try #require(await pings.next())
    ping.cancel()
    await #expect(throws: CancellationError.self) { try await ping.value }
    held.call(nil)
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

private final class HeldPong: Sendable {
  private let pong = Mutex<(@Sendable ((any Error)?) -> Void)?>(nil)
  func store(_ pong: @escaping @Sendable ((any Error)?) -> Void) { self.pong.withLock { $0 = pong } }
  func call(_ error: (any Error)?) { pong.withLock { $0 }?(error) }
}
