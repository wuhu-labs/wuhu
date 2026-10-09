#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import Serve
import ServeRouting
import Testing

@Suite struct WebSocketRoutingTests {
  @Test func routesUpgradeRequestsToWebSocketHandlers() async throws {
    var router = Router()
    router.webSocket("/echo/:name") { _, parameters in
      let name = parameters["name"] ?? ""
      return .webSocket { socket in
        for await message in socket.inbound {
          guard case let .text(text) = message else { continue }
          try? await socket.send(.text("\(name): \(text)"))
        }
        socket.close()
      }
    }

    let result = try await router.upgradingHandler(upgradeRequest(path: "/echo/amy"))
    guard case let .webSocket(session) = result else {
      Issue.record("expected an upgrade acceptance")
      return
    }

    let (server, client) = WebSocket.pair()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await session(server) }
      group.addTask {
        try? await client.send(.text("hi"))
        var inbound = client.inbound.makeAsyncIterator()
        #expect(await inbound.next() == .text("amy: hi"))
        client.close()
      }
    }
  }

  @Test func nonUpgradeRequestToWebSocketPathIsUpgradeRequired() async throws {
    var router = Router()
    router.webSocket("/ws") { _, _ in .webSocket { $0.close() } }

    let result = try await router.upgradingHandler(Request(url: URL(string: "http://app.wuhu.test/ws")!))
    guard case let .response(response) = result else {
      Issue.record("expected a plain response")
      return
    }
    #expect(response.status == .upgradeRequired)
    #expect(response.headers[.upgrade] == "websocket")
  }

  @Test func plainRoutesMaySharePathsWithWebSocketRoutes() async throws {
    var router = Router()
    router.get("/session/:id") { _, parameters in
      Response(status: .ok, body: .string("status \(parameters["id"] ?? "")"))
    }
    router.webSocket("/session/:id") { _, _ in .webSocket { $0.close() } }

    let plain = try await router.upgradingHandler(Request(url: URL(string: "http://app.wuhu.test/session/abc")!))
    guard case let .response(response) = plain else {
      Issue.record("expected the plain route to claim the non-upgrade request")
      return
    }
    #expect(response.status == .ok)
    #expect(try await response.text() == "status abc")

    let upgraded = try await router.upgradingHandler(upgradeRequest(path: "/session/abc"))
    guard case .webSocket = upgraded else {
      Issue.record("expected an upgrade acceptance")
      return
    }
  }

  @Test func plainRoutesServeThroughTheUpgradingHandler() async throws {
    var router = Router()
    router.get("/hello") { _, _ in Response(status: .ok, body: .string("hello")) }
    router.webSocket("/ws") { _, _ in .webSocket { $0.close() } }

    let ok = try await router.upgradingHandler(Request(url: URL(string: "http://app.wuhu.test/hello")!))
    guard case let .response(response) = ok else {
      Issue.record("expected a plain response")
      return
    }
    #expect(response.status == .ok)

    let missing = try await router.upgradingHandler(Request(url: URL(string: "http://app.wuhu.test/nope")!))
    guard case let .response(notFound) = missing else {
      Issue.record("expected a plain response")
      return
    }
    #expect(notFound.status == .notFound)
  }

  @Test func mostSpecificWebSocketRouteWinsOverEarlierCatchAll() async throws {
    var router = Router()
    router.webSocket("/*") { _, _ in .response(Response(status: .forbidden)) }
    router.webSocket("/v1/exec/:id") { _, parameters in
      .response(Response(status: .ok, body: .string("exec \(parameters["id"] ?? "")")))
    }

    let specific = try await router.upgradingHandler(upgradeRequest(path: "/v1/exec/abc"))
    guard case let .response(accepted) = specific else {
      Issue.record("expected the specific route's response")
      return
    }
    #expect(accepted.status == .ok)
    #expect(try await accepted.text() == "exec abc")

    let other = try await router.upgradingHandler(upgradeRequest(path: "/v1/other"))
    guard case let .response(refused) = other else {
      Issue.record("expected the catch-all's response")
      return
    }
    #expect(refused.status == .forbidden)
  }

  @Test func mountPrefixesWebSocketRoutes() async throws {
    var inner = Router()
    inner.webSocket("/connect") { _, _ in .webSocket { $0.close() } }
    var outer = Router()
    outer.mount("/v1/machine", inner)

    let result = try await outer.upgradingHandler(upgradeRequest(path: "/v1/machine/connect"))
    guard case .webSocket = result else {
      Issue.record("expected an upgrade acceptance")
      return
    }
  }
}

private func upgradeRequest(path: String) -> Request {
  var headers = RequestHeaders()
  headers.set("connection", "Upgrade")
  headers.set("upgrade", "websocket")
  headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
  headers.set("sec-websocket-version", "13")
  return Request(url: URL(string: "http://app.wuhu.test\(path)")!, headers: headers)
}
