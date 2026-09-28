#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import FetchWebSocket
import NIOSSL
import Serve
import ServeNIO
import ServeTLS
import Testing

@Suite(.serialized)
struct FetchWebSocketClientTests {
  @Test func connectsSendsAndReceivesBinaryFramesOverTCP() async throws {
    try await withEchoServer { port in
      let socket = try await WebSocketClient.connect(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
      var inbound = socket.inbound.makeAsyncIterator()

      try await socket.send([1, 2, 3])
      #expect(await inbound.next() == [1, 2, 3])

      let big = [UInt8](repeating: 7, count: 900 * 1024)
      try await socket.send(big)
      var echoed: [UInt8] = []
      while echoed.count < big.count, let chunk = await inbound.next() {
        echoed += chunk
      }
      #expect(echoed == big)
      socket.close()
    }
  }

  @Test func connectsOverTLSWithWSSRoundTrip() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity, upgrading: { _ in
      .webSocket { socket in
        for await message in socket.inbound {
          try? await socket.send(message)
        }
        socket.close()
      }
    })
    do {
      let port = try #require(server.boundAddress.port)
      var tls = TLSConfiguration.makeClientConfiguration()
      tls.certificateVerification = .none
      let socket = try await WebSocketClient.connect(
        url: URL(string: "wss://127.0.0.1:\(port)/ws")!,
        tls: .configuration(tls),
      )
      var inbound = socket.inbound.makeAsyncIterator()
      try await socket.send([4, 5, 6])
      #expect(await inbound.next() == [4, 5, 6])
      socket.close()
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func acceptsServerFramesUpToTheConfiguredCeiling() async throws {
    let payload = [UInt8](repeating: 9, count: 3 * 1024 * 1024)
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .webSocket { socket in
        try? await socket.send(.binary(payload))
        for await _ in socket.inbound {}
        socket.close()
      }
    })
    do {
      let port = try #require(server.boundAddress.port)
      let socket = try await WebSocketClient.connect(
        url: URL(string: "ws://127.0.0.1:\(port)/ws")!,
        maxFrameBytes: 4 * 1024 * 1024,
      )
      var received: [UInt8] = []
      for await chunk in socket.inbound {
        received += chunk
        if received.count >= payload.count { break }
      }
      #expect(received == payload)
      socket.close()
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func requestTargetKeepsPercentEncodedBytes() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { request in
      let target = request.url.path(percentEncoded: true)
        + (request.url.query(percentEncoded: true).map { "?\($0)" } ?? "")
      return .webSocket { socket in
        try? await socket.send(.text(target))
        for await _ in socket.inbound {}
        socket.close()
      }
    })
    do {
      let port = try #require(server.boundAddress.port)
      let socket = try await WebSocketClient.connect(
        url: URL(string: "ws://127.0.0.1:\(port)/ws/a%2Fb%20c?q=x%2Fy")!,
      )
      var inbound = socket.inbound.makeAsyncIterator()
      #expect(await inbound.next() == Array("/ws/a%2Fb%20c?q=x%2Fy".utf8))
      socket.close()
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func upgradeHeadersReachTheHandlerAndRefusalThrows() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { request in
      guard request.headers["x-token"] == "good" else {
        return .response(Response(status: .unauthorized, body: .string("denied\n")))
      }
      return .webSocket { socket in
        try? await socket.send(.text("hello"))
        for await _ in socket.inbound {}
        socket.close()
      }
    })
    do {
      let port = try #require(server.boundAddress.port)
      let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
      await #expect(throws: WebSocketClientError.refused) {
        _ = try await WebSocketClient.connect(url: url, headers: [("x-token", "bad")])
      }
      let socket = try await WebSocketClient.connect(url: url, headers: [("x-token", "good")])
      var inbound = socket.inbound.makeAsyncIterator()
      #expect(await inbound.next() == Array("hello".utf8))
      socket.close()
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func serverCloseFinishesInboundAndFailsSend() async throws {
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      .webSocket { socket in
        socket.close()
      }
    })
    do {
      let port = try #require(server.boundAddress.port)
      let socket = try await WebSocketClient.connect(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
      for await _ in socket.inbound {}
      await #expect(throws: (any Error).self) {
        for _ in 0 ..< 10000 {
          try await socket.send([1])
        }
      }
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }
}

private func withEchoServer(_ operation: (Int) async throws -> Void) async throws {
  let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { request in
    guard Serve.isWebSocketUpgradeRequest(request) else {
      return .response(Response(status: .badRequest))
    }
    return .webSocket { socket in
      for await message in socket.inbound {
        try? await socket.send(message)
      }
      socket.close()
    }
  })
  do {
    try await operation(try #require(server.boundAddress.port))
    await server.shutdown()
  } catch {
    await server.shutdown()
    throw error
  }
}
