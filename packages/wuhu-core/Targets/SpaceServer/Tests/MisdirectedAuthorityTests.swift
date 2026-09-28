import Fetch
import Foundation
import JSONValue
import ServeTesting
@testable import SpaceServer
import Testing

@Suite struct MisdirectedAuthorityTests {
  @Test func apiListenerRejectsTheWebOriginsAuthority() async throws {
    let harness = try Harness(origin: "https://api.example", webPort: 4101, webOrigin: "https://web.example")

    let own = try await harness.api(Request(url: URL(string: "https://api.example/v1/server")!))
    #expect(own.status == .ok)

    let coalesced = try await harness.api(Request(url: URL(string: "https://web.example/v1/server")!))
    #expect(coalesced.status == .misdirectedRequest)
    #expect(coalesced.headers[.accessControlAllowOrigin] == nil)

    let other = try await harness.api(Request(url: URL(string: "https://space/v1/server")!))
    #expect(other.status == .ok)
  }

  @Test func theApiWallDoesNotAnswerBeforeTheMisdirectionCheck() async throws {
    let harness = try Harness(dev: false, origin: "https://api.example", webPort: 4101, webOrigin: "https://web.example")

    var bootstrap = Request(url: URL(string: "https://web.example/_/session")!, method: .post)
    bootstrap.headers[.origin] = "https://api.example"
    let coalesced = try await harness.api(bootstrap)
    #expect(coalesced.status == .misdirectedRequest)

    var preflight = Request(url: URL(string: "https://web.example/_/session")!, method: .options)
    preflight.headers[.origin] = "https://api.example"
    #expect(try await harness.api(preflight).status == .misdirectedRequest)

    let walled = try await harness.api(Request(url: URL(string: "https://api.example/v1/tools/ls")!, method: .post))
    #expect(walled.status == .unauthorized)
  }

  @Test func webListenerRejectsTheApiOriginsAuthority() async throws {
    let harness = try Harness(origin: "https://api.example", webPort: 4101, webOrigin: "https://web.example")
    _ = try await harness.direct("write", .object(["path": "/page.html", "content": "<h1>hi</h1>"]))
    let web = ServeTesting.client(misdirecting(
      SpaceServer.webHandler(space: harness.space, apiPort: Harness.apiPort, advertisedOrigin: "https://api.example", dev: true),
      own: "https://web.example",
      other: "https://api.example",
    ))

    let own = try await web(Request(url: URL(string: "https://web.example/page.html")!))
    #expect(own.status == .ok)

    var coalesced = Request(url: URL(string: "https://api.example/_/session")!, method: .post)
    coalesced.headers[.origin] = "https://api.example"
    let rejected = try await web(coalesced)
    #expect(rejected.status == .misdirectedRequest)
    #expect(rejected.headers[.accessControlAllowOrigin] == nil)

    let page = try await web(Request(url: URL(string: "https://api.example/page.html")!))
    #expect(page.status == .misdirectedRequest)
  }

  @Test func aGroupHostBelongsToTheListenerOfItsHost() async throws {
    let harness = try Harness(origin: "https://api.example", webPort: 4101, webOrigin: "https://web.example")
    _ = try await harness.direct("write", .object(["path": "/page.html", "content": "<h1>hi</h1>"]))
    let web = ServeTesting.client(misdirecting(
      SpaceServer.webHandler(
        space: harness.space, apiPort: Harness.apiPort, advertisedOrigin: "https://api.example",
        webOrigin: "https://web.example", dev: true,
      ),
      own: "https://web.example",
      other: "https://api.example",
    ))

    let coalescedOnAPI = try await harness.api(Request(url: URL(string: "https://alice.web.example/v1/server")!))
    #expect(coalescedOnAPI.status == .misdirectedRequest)
    let ownOnAPI = try await harness.api(Request(url: URL(string: "https://alice.api.example/v1/server")!))
    #expect(ownOnAPI.status != .misdirectedRequest)

    let coalescedOnWeb = try await web(Request(url: URL(string: "https://alice.api.example/page.html")!))
    #expect(coalescedOnWeb.status == .misdirectedRequest)
    let ownOnWeb = try await web(Request(url: URL(string: "https://nobody.web.example/page.html")!))
    #expect(ownOnWeb.status == .notFound)
    // Two labels down is no group host of either listener.
    let deeper = try await web(Request(url: URL(string: "https://a.b.api.example/page.html")!))
    #expect(deeper.status == .ok)
  }

  @Test func aNestedSiblingsHostIsNeverAGroupOfTheOther() async throws {
    // The web host one label under the API host.
    let nested = try Harness(origin: "https://api.example", webPort: 4101, webOrigin: "https://web.api.example")
    _ = try await nested.direct("write", .object(["path": "/page.html", "content": "<h1>hi</h1>"]))
    #expect(try await nested.api(Request(url: URL(string: "https://web.api.example/v1/server")!)).status == .misdirectedRequest)
    #expect(try await nested.api(Request(url: URL(string: "https://alice.web.api.example/v1/server")!)).status == .misdirectedRequest)
    #expect(try await nested.api(Request(url: URL(string: "https://api.example/v1/server")!)).status == .ok)
    let nestedWeb = ServeTesting.client(misdirecting(
      SpaceServer.webHandler(
        space: nested.space, apiPort: Harness.apiPort, advertisedOrigin: "https://api.example",
        webOrigin: "https://web.api.example", dev: true,
      ),
      own: "https://web.api.example",
      other: "https://api.example",
    ))
    #expect(try await nestedWeb(Request(url: URL(string: "https://web.api.example/page.html")!)).status == .ok)
    #expect(try await nestedWeb(Request(url: URL(string: "https://api.example/page.html")!)).status == .misdirectedRequest)

    // The API host one label under the web host.
    let web = ServeTesting.client(misdirecting(
      SpaceServer.webHandler(
        space: nested.space, apiPort: Harness.apiPort, advertisedOrigin: "https://api.web.example",
        webOrigin: "https://web.example", dev: true,
      ),
      own: "https://web.example",
      other: "https://api.web.example",
    ))
    #expect(try await web(Request(url: URL(string: "https://api.web.example/page.html")!)).status == .misdirectedRequest)
    #expect(try await web(Request(url: URL(string: "https://web.example/page.html")!)).status == .ok)
    let api = try Harness(origin: "https://api.web.example", webPort: 4101, webOrigin: "https://web.example")
    #expect(try await api.api(Request(url: URL(string: "https://web.example/v1/server")!)).status == .misdirectedRequest)
    #expect(try await api.api(Request(url: URL(string: "https://api.web.example/v1/server")!)).status == .ok)
  }

  @Test func oneHostnameForBothListenersIsNeverMisdirected() async throws {
    let harness = try Harness(origin: "https://example.test", webPort: 4101, webOrigin: "https://example.test:4101")
    _ = try await harness.direct("write", .object(["path": "/page.html", "content": "<h1>hi</h1>"]))

    let api = try await harness.api(Request(url: URL(string: "https://example.test/v1/server")!))
    #expect(api.status == .ok)

    let web = ServeTesting.client(misdirecting(
      SpaceServer.webHandler(space: harness.space, apiPort: Harness.apiPort, advertisedOrigin: "https://example.test", dev: true),
      own: "https://example.test:4101",
      other: "https://example.test",
    ))
    let page = try await web(Request(url: URL(string: "https://example.test/page.html")!))
    #expect(page.status == .ok)
  }

  @Test func listenersWithoutAPairedOriginAnswerEveryAuthority() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/page.html", "content": "<h1>hi</h1>"]))

    let api = try await harness.api(Request(url: URL(string: "https://anything.example/v1/server")!))
    #expect(api.status == .ok)

    let web = try await harness.web(Request(url: URL(string: "https://anything.example/page.html")!))
    #expect(web.status == .ok)
  }
}
