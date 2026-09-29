import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

// One listener: the bare host is the API and the web app, `<group>.<host>`
// that group's content, a name deeper under the host 421, any other name the
// API.
@Suite struct HostRoutingTests {
  static let origin = "https://space.test:5530"

  struct Rig {
    let harness: Harness
    let alice: AccountID
    let aliceGroup: GroupID
  }

  func rig(
    dev: Bool = false, publicRead: Bool = false, origin: String? = Self.origin, webApp: WebApp? = nil,
  ) async throws -> Rig {
    let harness = try Harness(dev: dev, publicRead: publicRead, origin: origin, webApp: webApp)
    let alice = try await harness.space.addAccount(kind: .human, name: "alice").id
    let rig = Rig(harness: harness, alice: alice, aliceGroup: try await harness.space.ensurePersonalGroup(account: alice))
    for group in [GroupID.shared, rig.aliceGroup] {
      _ = try await harness.space.fs(group).write("/plan.md", Data("\(group.rawValue) plan".utf8), ifMatch: nil)
    }
    return rig
  }

  func send(
    _ rig: Rig, _ url: String, method: HTTPRequest.Method = .get, headers: [String: String] = [:],
  ) async throws -> Response {
    var request = Request(url: URL(string: url)!, method: method)
    for (name, value) in headers { request.headers[HTTPField.Name(name)!] = value }
    return try await rig.harness.api(request)
  }

  func cookie(_ rig: Rig, _ group: GroupID) async throws -> String {
    "wuhu_read=" + (try await rig.harness.space.createReadSession(
      account: rig.alice, group: group, expiresAt: fixedDate.addingTimeInterval(3600),
    )).rawValue
  }

  @Test func theBareHostServesTheAPIAndTheWebAppButNoContent() async throws {
    let r = try await rig(dev: true, webApp: WebApp(files: ["index.html": Data("<html>shell</html>".utf8)])!)
    let info = try await send(r, "https://space.test:5530/v1/server")
    #expect(info.status == .ok)
    #expect(try await json(info).object?["contentBase"] == "space.test:5530")

    let file = try await send(r, "https://space.test:5530/plan.md")
    #expect(try await file.text() == "<html>shell</html>")
    for path in ["/_/query?sql=SELECT%201", "/_/shell.js", "/_/space/query?sql=SELECT%201"] {
      #expect(try await send(r, "https://space.test:5530\(path)").text() == "<html>shell</html>", "\(path)")
    }
    let mint = try await send(r, "https://space.test:5530/_/session", method: .post)
    #expect(mint.status != .noContent)
    #expect(mint.headers[.setCookie] == nil)
  }

  @Test func aGroupHostServesContentAndNoAPI() async throws {
    let r = try await rig(dev: true)
    let host = "https://\(r.aliceGroup.rawValue).space.test:5530"
    #expect(try await send(r, "\(host)/plan.md").text() == "\(r.aliceGroup.rawValue) plan")
    #expect(try await send(r, "https://shared.space.test:5530/plan.md").text() == "shared plan")
    let download = try await send(r, "\(host)/plan.md?download=1")
    #expect(download.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename*=UTF-8''plan.md")
    #expect(try await download.text() == "\(r.aliceGroup.rawValue) plan")

    let info = try await send(r, "\(host)/v1/server")
    #expect(info.status == .notFound)
    #expect(try await !info.text().contains("contentBase"))
    #expect(try await send(r, "\(host)/v1/tools/ls", method: .post).status == .methodNotAllowed)
    #expect(try await send(r, "https://shared.space.test:5530/v1/groups").status == .notFound)
  }

  @Test func aHostMatchesWithATrailingDotAndInAnyCase() async throws {
    let content = try #require(ContentHost(origin: "https://Space.Test.:5530"))
    #expect(content.host == "space.test")
    #expect(content.base == "space.test:5530")
    #expect(content.plane(of: "alice.space.test.") == .content(GroupID(rawValue: "alice")))
    #expect(content.plane(of: "ALICE.Space.TEST") == .content(GroupID(rawValue: "alice")))
    #expect(content.plane(of: "space.test.") == .api)
    #expect(content.plane(of: "a.b.space.test.") == .misdirected)

    let r = try await rig(dev: true)
    let dotted = try await send(r, "https://\(r.aliceGroup.rawValue).space.test.:5530/plan.md")
    #expect(try await dotted.text() == "\(r.aliceGroup.rawValue) plan")
  }

  @Test func withNoOriginTheLoopbackAddressesPairAsTheWebApp() async throws {
    let r = try await rig(origin: nil)
    let page = "https://\(r.aliceGroup.rawValue).localhost:5530/plan.md"
    let alices = try await cookie(r, r.aliceGroup)
    for requester in ["https://localhost:5530", "https://127.0.0.1:5530", "https://[::1]:5530"] {
      let response = try await send(r, page, headers: ["Cookie": alices, "Origin": requester])
      #expect(response.status == .ok, "\(requester)")
      #expect(response.headers[.accessControlAllowOrigin] == requester)
      #expect(
        response.headers[HTTPField.Name("Content-Security-Policy")!]
          == "frame-ancestors 'self' https://localhost:5530 https://127.0.0.1:5530 https://[::1]:5530",
      )
    }
    #expect(
      try await send(r, page, headers: ["Cookie": alices, "Origin": "https://127.0.0.2:5530"])
        .headers[.accessControlAllowOrigin] == nil,
    )

    let named = try await rig()
    let response = try await send(
      named, "https://\(named.aliceGroup.rawValue).space.test:5530/plan.md",
      headers: ["Cookie": try await cookie(named, named.aliceGroup), "Origin": "https://127.0.0.1:5530"],
    )
    #expect(response.headers[.accessControlAllowOrigin] == nil)
    #expect(response.headers[HTTPField.Name("Content-Security-Policy")!] == "frame-ancestors 'self' https://space.test:5530")
  }

  @Test func anUnknownGroupHostIsNotFound() async throws {
    let r = try await rig(dev: true)
    let response = try await send(r, "https://nowhere.space.test:5530/plan.md")
    #expect(response.status == .notFound)
    #expect(try await json(response).object?["code"] == "unknownGroup")
  }

  @Test func publicReadOpensSharedHostOnly() async throws {
    let closed = try await rig()
    #expect(try await send(closed, "https://shared.space.test:5530/plan.md").status == .unauthorized)

    let open = try await rig(publicRead: true)
    #expect(try await send(open, "https://shared.space.test:5530/plan.md").status == .ok)
    #expect(try await send(open, "https://\(open.aliceGroup.rawValue).space.test:5530/plan.md").status == .unauthorized)
    // The API wall stays up.
    #expect(try await send(open, "https://space.test:5530/v1/tools/ls", method: .post).status == .unauthorized)
  }

  @Test func aCookieIsScopedToTheGroupHostItWasMintedOn() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.aliceGroup)
    let shared = try await cookie(r, .shared)
    let aliceHost = "https://\(r.aliceGroup.rawValue).space.test:5530/plan.md"
    #expect(try await send(r, aliceHost, headers: ["Cookie": alices]).status == .ok)
    #expect(try await send(r, aliceHost, headers: ["Cookie": shared]).status == .unauthorized)
    #expect(try await send(r, "https://shared.space.test:5530/plan.md", headers: ["Cookie": shared]).status == .ok)
    #expect(try await send(r, "https://shared.space.test:5530/plan.md", headers: ["Cookie": alices]).status == .unauthorized)
    // Content cookies are never an API credential.
    let api = try await send(r, "https://space.test:5530/v1/tools/ls", method: .post, headers: ["Cookie": alices])
    #expect(api.status == .unauthorized)
  }

  @Test func aNameDeeperUnderTheHostIsMisdirected() async throws {
    let r = try await rig()
    for url in [
      "https://a.b.space.test:5530/v1/server", "https://a.\(r.aliceGroup.rawValue).space.test:5530/plan.md",
    ] {
      let response = try await send(r, url, headers: ["Origin": Self.origin])
      #expect(response.status == .misdirectedRequest, "\(url)")
      #expect(response.headers[.accessControlAllowOrigin] == nil)
    }
    // The wall does not answer first.
    #expect(try await send(r, "https://a.b.space.test:5530/v1/tools/ls", method: .post).status == .misdirectedRequest)
    #expect(try await send(r, "https://a.b.space.test:5530/_/session", method: .post).status == .misdirectedRequest)
  }

  @Test func everyOtherNameReachesTheAPI() async throws {
    let r = try await rig(dev: true)
    for host in ["192.168.1.5:5530", "localhost:5530", "box.local", "space.test.evil:5530", "evilspace.test"] {
      let response = try await send(r, "https://\(host)/v1/server")
      #expect(response.status == .ok, "\(host)")
      #expect(try await json(response).object?["contentBase"] == "space.test:5530")
    }
  }

  // An old share link `https://<g>.<host>/<path>` opened in a tab with no read
  // session goes to the web app's own URL for it.
  @Test func aCookielessTopLevelNavigationOpensTheWebApp() async throws {
    let r = try await rig()
    let navigation = ["Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "none"]
    let group = r.aliceGroup.rawValue
    let opened = try await send(r, "https://\(group).space.test:5530/notes/a%20b.md?q=1&group=x", headers: navigation)
    #expect(opened.status == .seeOther)
    #expect(opened.headers[.location] == "https://space.test:5530/notes/a%20b.md?q=1&group=\(group)")
    #expect(opened.headers[.cacheControl] == "no-store")
    let shared = try await send(r, "https://shared.space.test:5530/plan.md", headers: navigation)
    #expect(shared.status == .seeOther)
    #expect(shared.headers[.location] == "https://space.test:5530/plan.md")

    // A frame, a fetch, and a navigation the cookie admits get the content.
    let framed = ["Sec-Fetch-Dest": "iframe", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "same-site"]
    #expect(try await send(r, "https://\(group).space.test:5530/plan.md", headers: framed).status == .unauthorized)
    let fetched = ["Sec-Fetch-Dest": "empty", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-site", "Origin": Self.origin]
    #expect(try await send(r, "https://\(group).space.test:5530/plan.md", headers: fetched).status == .unauthorized)
    #expect(try await send(r, "https://\(group).space.test:5530/plan.md").status == .unauthorized)
    var admitted = navigation
    admitted["Cookie"] = try await cookie(r, r.aliceGroup)
    let page = try await send(r, "https://\(group).space.test:5530/plan.md", headers: admitted)
    #expect(page.status == .ok)
    #expect(try await page.text() == "\(group) plan")

    let open = try await rig(publicRead: true)
    let board = try await send(open, "https://shared.space.test:5530/plan.md", headers: navigation)
    #expect(board.status == .ok)
    #expect(try await board.text() == "shared plan")
  }

  @Test func theSmartBannerFoldsTheGroupIntoTheHost() async throws {
    let shell = WebApp(files: ["index.html": Data("<html><head></head></html>".utf8)])!
    let r = try await rig(dev: true, webApp: shell)
    func banner(_ url: String) async throws -> String {
      let text = try await send(r, url).text()
      let start = try #require(text.range(of: #"content=""#)).upperBound
      return String(text[start...].prefix { $0 != "\"" })
    }
    #expect(
      try await banner("https://space.test:5530/notes/a.md?group=alice-bird-sky&q=1")
        == "app-id=6807771419, app-argument=wuhu://alice-bird-sky.space.test:5530/notes/a.md?q=1",
    )
    #expect(
      try await banner("https://space.test:5530/notes/a.md?group=shared")
        == "app-id=6807771419, app-argument=wuhu://space.test:5530/notes/a.md",
    )
    #expect(try await banner("https://space.test:5530/notes/a.md?group=No%2FSuch") == "app-id=6807771419")
  }
}
