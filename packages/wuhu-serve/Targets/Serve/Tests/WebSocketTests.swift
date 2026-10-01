#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import Serve
import Testing

@Suite struct WebSocketTests {
  @Test func pairDeliversMessagesInBothDirections() async throws {
    let (a, b) = WebSocket.pair()

    try await a.send(.binary([1, 2, 3]))
    try await a.send(.text("hello"))
    try await b.send(.binary([9]))

    var bInbound = b.inbound.makeAsyncIterator()
    #expect(await bInbound.next() == .binary([1, 2, 3]))
    #expect(await bInbound.next() == .text("hello"))

    var aInbound = a.inbound.makeAsyncIterator()
    #expect(await aInbound.next() == .binary([9]))
  }

  @Test func pairCloseFinishesBothSidesAndFailsSends() async throws {
    let (a, b) = WebSocket.pair()
    try await a.send(.binary([7]))
    a.close()

    var bInbound = b.inbound.makeAsyncIterator()
    #expect(await bInbound.next() == .binary([7]))
    #expect(await bInbound.next() == nil)

    var aInbound = a.inbound.makeAsyncIterator()
    #expect(await aInbound.next() == nil)

    await #expect(throws: ServeError.webSocketClosed) {
      try await b.send(.binary([1]))
    }
    await #expect(throws: ServeError.webSocketClosed) {
      try await a.send(.text("late"))
    }
  }

  @Test func pairAbortFinishesBothSidesAndFailsSends() async throws {
    let (a, b) = WebSocket.pair()
    a.abort()
    var aInbound = a.inbound.makeAsyncIterator()
    var bInbound = b.inbound.makeAsyncIterator()
    #expect(await aInbound.next() == nil)
    #expect(await bInbound.next() == nil)
    await #expect(throws: ServeError.webSocketClosed) { try await a.send(.text("late")) }
    await #expect(throws: ServeError.webSocketClosed) { try await b.send(.text("late")) }
  }

  @Test func recognizesWebSocketUpgradeRequests() throws {
    #expect(Serve.isWebSocketUpgradeRequest(upgradeRequest()))
    #expect(Serve.isWebSocketUpgradeRequest(upgradeRequest(connection: "keep-alive, Upgrade")))

    #expect(!Serve.isWebSocketUpgradeRequest(upgradeRequest(method: .post)))
    #expect(!Serve.isWebSocketUpgradeRequest(upgradeRequest(connection: "keep-alive")))
    #expect(!Serve.isWebSocketUpgradeRequest(upgradeRequest(upgrade: "h2c")))
    #expect(!Serve.isWebSocketUpgradeRequest(upgradeRequest(key: nil)))
    #expect(!Serve.isWebSocketUpgradeRequest(upgradeRequest(version: "8")))
    #expect(!Serve.isWebSocketUpgradeRequest(Request(url: URL(string: "http://app.wuhu.test/ws")!)))
  }
}

func upgradeRequest(
  path: String = "/ws",
  method: Fetch.Method = .get,
  connection: String = "Upgrade",
  upgrade: String = "websocket",
  key: String? = "dGhlIHNhbXBsZSBub25jZQ==",
  version: String = "13",
) -> Request {
  var headers = RequestHeaders()
  headers.set("connection", connection)
  headers.set("upgrade", upgrade)
  if let key {
    headers.set("sec-websocket-key", key)
  }
  headers.set("sec-websocket-version", version)
  return Request(url: URL(string: "http://app.wuhu.test\(path)")!, method: method, headers: headers)
}
