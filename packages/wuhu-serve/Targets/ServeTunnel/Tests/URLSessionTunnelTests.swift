import Fetch
import FetchTunnel
import FetchTunnelURLSession
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
}
