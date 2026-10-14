#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchTunnel
import FetchTunnelWebSocket
import FetchWebSocket
import Serve
import ServeNIO
import Testing

@Test(arguments: [WebSocketLimits(frameBytes: 64 << 10), WebSocketLimits(messageBytes: 64 << 10), WebSocketLimits(outboundMessageBytes: 64 << 10)])
func nioTunnelTransportExposesSmallestMessageCap(limits: WebSocketLimits) async throws {
  let (stream, continuation) = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
  defer { continuation.finish() }
  let connector = WebSocketConnector { _ in
    WebSocketConnection(responseHeaders: [.init("sec-websocket-protocol")!: TunnelTransport.webSocketSubprotocol], inbound: .init(stream), send: { _ in }, close: { _ in }, abort: {})
  }
  let transport = try await TunnelWebSocket.connect(.init(url: .init(string: "ws://example.test/")!, limits: limits), connector: connector)
  #expect(transport.maxMessageBytes == 64 << 10)
  #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(chunkBytes: 64 << 10)) }
}

@Test(.timeLimit(.minutes(1)))
func serverDecoderCapRejectsIncompatibleTunnelLimitsBeforeTraffic() async throws {
  let (completed, completion) = AsyncStream<(Int, TunnelError?)>.makeStream()
  let server = try await ServeNIOServer.bind(port: 0, options: .init(maximumWebSocketFrameBytes: 1024), upgrading: { _ in
    .boundedWebSocket(limits: .init(messageBytes: 64 << 10), subprotocol: TunnelTransport.webSocketSubprotocol) { transport in
      let failure: TunnelError?
      do { _ = try Tunnel(over: transport); failure = nil }
      catch { failure = error as? TunnelError }
      completion.yield((transport.maxMessageBytes, failure))
      transport.abort()
    }
  })
  do {
    let port = try #require(server.boundAddress.port)
    let connection = try? await WebSocketConnector.live.connect(.init(url: .init(string: "ws://127.0.0.1:\(port)/")!, headers: .init(values: ["sec-websocket-protocol": TunnelTransport.webSocketSubprotocol])))
    var events = completed.makeAsyncIterator()
    let result = try #require(await events.next())
    #expect(result.0 == 1024)
    #expect(result.1 == .invalidConfiguration)
    connection?.abort()
    completion.finish()
    await server.shutdown()
  } catch { completion.finish(); await server.shutdown(); throw error }
}
