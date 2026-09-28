import Assertion
import Crypto
import Fetch
import FetchSSE
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceServer
import SpaceTools
import Testing

// `<group>.<host>` on the web origin serves that group, to its members, with a
// cookie minted on that host; the bare host stays `shared`.
@Suite struct WebGroupHostTests {
  static let origin = "https://space.test:5530"
  static let bare = "space.test:5531"

  struct Rig {
    let harness: Harness
    let alice: AccountID
    let bob: AccountID
    let aliceGroup: GroupID
    let bobGroup: GroupID

    var aliceHost: String { "\(aliceGroup.rawValue).space.test:5531" }
    var bobHost: String { "\(bobGroup.rawValue).space.test:5531" }
  }

  func rig(publicRead: Bool = false) async throws -> Rig {
    let harness = try Harness(dev: false, publicRead: publicRead, origin: Self.origin)
    let alice = try await harness.space.addAccount(kind: .human, name: "alice").id
    let bob = try await harness.space.addAccount(kind: .human, name: "bob").id
    let rig = Rig(
      harness: harness, alice: alice, bob: bob,
      aliceGroup: try await harness.space.ensurePersonalGroup(account: alice),
      bobGroup: try await harness.space.ensurePersonalGroup(account: bob),
    )
    try await put(rig, .shared, "/plan.md", "shared plan")
    try await put(rig, rig.aliceGroup, "/plan.md", "alice plan")
    try await put(rig, rig.aliceGroup, "/alice-only.md", "mine")
    return rig
  }

  func put(_ rig: Rig, _ group: GroupID, _ path: String, _ content: String) async throws {
    let context = SpaceToolContext(space: rig.harness.space, principal: Principal(actor: .anonymous, group: group))
    _ = try await SpaceToolbox.all.first { $0.name == "write" }!
      .run(context, input: .object(["path": .string(path), "content": .string(content)]))
  }

  func cookie(_ rig: Rig, _ account: AccountID, _ group: GroupID) async throws -> String {
    "wuhu_read=" + (try await rig.harness.space.createReadSession(
      account: account, group: group, expiresAt: fixedDate.addingTimeInterval(3600),
    )).rawValue
  }

  func get(
    _ rig: Rig, _ host: String, _ pathAndQuery: String,
    cookie: String? = nil, site: String? = nil, mode: String? = nil, origin: String? = nil,
    method: HTTPRequest.Method = .get,
  ) async throws -> Response {
    var request = Request(url: URL(string: "https://\(host)\(pathAndQuery)")!, method: method)
    if let cookie { request.headers[.cookie] = cookie }
    if let site { request.headers[HTTPField.Name("Sec-Fetch-Site")!] = site }
    if let mode { request.headers[HTTPField.Name("Sec-Fetch-Mode")!] = mode }
    if let origin { request.headers[.origin] = origin }
    return try await rig.harness.web(request)
  }

  func code(_ response: Response) async throws -> String? {
    try await json(response).object?["code"]?.stringValue
  }

  @Test func aGroupHostServesItsGroupToAMemberWithThatHostsCookie() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let page = try await get(r, r.aliceHost, "/plan.md", cookie: alices)
    #expect(page.status == .ok)
    #expect(try await page.text() == "alice plan")
    #expect(page.headers[HTTPField.Name("Wuhu-Viewer")!] == r.alice.rawValue)

    let shared = try await get(r, Self.bare, "/plan.md", cookie: try await cookie(r, r.alice, .shared))
    #expect(try await shared.text() == "shared plan")
    #expect(try await get(r, Self.bare, "/alice-only.md", cookie: try await cookie(r, r.alice, .shared)).status == .notFound)

    // A cookie is good on the host it was minted on only.
    #expect(try await get(r, Self.bare, "/plan.md", cookie: alices).status == .unauthorized)
    #expect(try await get(r, r.bobHost, "/plan.md", cookie: alices).status == .unauthorized)
    let bobsShared = try await cookie(r, r.bob, .shared)
    #expect(try await get(r, r.aliceHost, "/plan.md", cookie: bobsShared).status == .unauthorized)

    // A session bound to a group its account is not (or no longer) in reads nothing.
    let foreign = try await get(r, r.aliceHost, "/plan.md", cookie: try await cookie(r, r.bob, r.aliceGroup))
    #expect(foreign.status == .forbidden)
    #expect(try await code(foreign) == "groupForbidden")
  }

  // A cross-group DM homed in alice's group: bob, a member acting in his own
  // group, opens its attachment on his own host at the hostless path; someone
  // outside the DM gets what a missing file gets.
  @Test func aDMMemberOpensItsAttachmentOnTheirOwnHost() async throws {
    let r = try await rig()
    let space = r.harness.space
    let dm = try await space.sessions.createConversation(members: [r.alice.rawValue, r.bob.rawValue], in: r.aliceGroup)
    let posted = try await space.sessions.post(
      .conversation(dm), messageID: MessageID("m1"),
      sender: Sender(id: r.alice.rawValue, timeZone: TimeZone(identifier: "UTC")!),
      content: .init(text: "see"), uploads: [AttachmentUpload(name: "dm.txt", bytes: Array("dm bytes".utf8))],
      acting: Principal(actor: .person(persona: r.alice.rawValue, account: r.alice), group: r.aliceGroup),
    )
    let path = try #require(posted.message.content.attachments.first?.path)
    #expect(path.hasPrefix("/_/conversations/\(dm.rawValue)/attachments/"))

    let bobs = try await get(r, r.bobHost, path, cookie: try await cookie(r, r.bob, r.bobGroup))
    #expect(bobs.status == .ok)
    #expect(try await bobs.text() == "dm bytes")
    let alices = try await get(r, r.aliceHost, path, cookie: try await cookie(r, r.alice, r.aliceGroup))
    #expect(try await alices.text() == "dm bytes")

    let carol = try await space.addAccount(kind: .human, name: "carol").id
    let carolGroup = try await space.ensurePersonalGroup(account: carol)
    let carolHost = "\(carolGroup.rawValue).space.test:5531"
    #expect(try await get(r, carolHost, path, cookie: try await cookie(r, carol, carolGroup)).status == .notFound)
  }

  @Test func queryAndObserveOnAGroupHostReadThatGroup() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let sql = "SELECT%20path%20FROM%20docs%20ORDER%20BY%20path"
    let query = try await get(r, r.aliceHost, "/_/query?sql=\(sql)", cookie: alices)
    #expect(query.status == .ok)
    let rows = try await query.text()
    #expect(rows.contains("/alice-only.md"))

    let observe = try await get(r, r.aliceHost, "/_/observe?sql=\(sql)", cookie: alices)
    #expect(observe.status == .ok)
    for try await event in observe.sse() {
      #expect(event.data.contains("/alice-only.md"))
      break
    }

    let bareRows = try await get(r, Self.bare, "/_/query?sql=\(sql)", cookie: try await cookie(r, r.alice, .shared)).text()
    #expect(!bareRows.contains("/alice-only.md"))
  }

  @Test func aSharedPageCannotReachAGroupByAddress() async throws {
    let r = try await rig()
    let sql = "SELECT%20*%20FROM%20%22wuhu://\(r.aliceGroup.rawValue).localspace/docs%22"
    let response = try await get(r, Self.bare, "/_/query?sql=\(sql)", cookie: try await cookie(r, r.alice, .shared))
    #expect(response.status == .unprocessableContent)
    #expect(try await response.text().contains("no such table: wuhu://\(r.aliceGroup.rawValue).localspace/docs"))
  }

  @Test func aSiblingHostsScriptIsRefusedAndNeverReflected() async throws {
    let r = try await rig()
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    for path in ["/_/query?sql=SELECT%201", "/_/observe?sql=SELECT%201"] {
      for requester in [
        "https://\(r.bobHost)", "https://\(r.bobGroup.rawValue).space.test:5530",
        "https://\(r.bobGroup.rawValue).space.test:\(Harness.apiPort)", "https://space.test:5531",
      ] {
        let refused = try await get(r, r.aliceHost, path, cookie: alices, site: "same-site", origin: requester)
        #expect(refused.status == .forbidden, "\(path) from \(requester)")
        #expect(try await code(refused) == "crossOrigin")
        #expect(refused.headers[.accessControlAllowOrigin] == nil)
      }
      let crossSite = try await get(r, r.aliceHost, path, cookie: alices, site: "cross-site", origin: "https://evil.example")
      #expect(crossSite.status == .forbidden)
    }
    let sibling = try await get(r, r.aliceHost, "/_/session", cookie: alices, site: "same-site", origin: "https://\(r.bobHost)", method: .delete)
    #expect(sibling.status == .forbidden)
    #expect(sibling.headers[.setCookie] == nil)

    // The page's own scripts, the paired SPA, and a caller that sends no
    // Sec-Fetch-Site (the native app) still read.
    let own = try await get(r, r.aliceHost, "/_/query?sql=SELECT%201", cookie: alices, site: "same-origin")
    #expect(own.status == .ok)
    let spa = "https://\(r.aliceGroup.rawValue).space.test:5530"
    let paired = try await get(r, r.aliceHost, "/_/query?sql=SELECT%201", cookie: alices, site: "same-site", origin: spa)
    #expect(paired.status == .ok)
    #expect(paired.headers[.accessControlAllowOrigin] == spa)
    #expect(try await get(r, r.aliceHost, "/_/query?sql=SELECT%201", cookie: alices).status == .ok)
    // A page opened from anywhere is still a page.
    #expect(try await get(r, r.aliceHost, "/plan.md", cookie: alices, site: "cross-site", mode: "navigate").status == .ok)
  }

  @Test func aSiblingCannotEmbedAGroupHostsFilesButMayNavigateToThem() async throws {
    let r = try await rig()
    try await put(r, r.aliceGroup, "/x.js", "alert(1)")
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    // <script src>, <img>, <link rel=stylesheet>: no-cors, so no Origin to pair.
    for (path, mode) in [("/x.js", "no-cors"), ("/plan.md", "no-cors"), ("/missing.css", "no-cors"), ("/x.js", "cors")] {
      for site in ["same-site", "cross-site"] {
        let embedded = try await get(r, r.aliceHost, path, cookie: alices, site: site, mode: mode)
        #expect(embedded.status == .forbidden, "\(path) \(site) \(mode)")
        #expect(try await code(embedded) == "crossOrigin")
      }
    }
    // HEAD answers the same wall, so no oracle in onload/onerror either.
    let head = try await get(r, r.aliceHost, "/plan.md", cookie: alices, site: "same-site", mode: "no-cors", method: .head)
    #expect(head.status == .forbidden)

    for site in ["same-site", "cross-site"] {
      let navigated = try await get(r, r.aliceHost, "/plan.md", cookie: alices, site: site, mode: "navigate")
      #expect(navigated.status == .ok)
      #expect(try await navigated.text() == "alice plan")
    }
    let own = try await get(r, r.aliceHost, "/x.js", cookie: alices, site: "same-origin", mode: "no-cors")
    #expect(own.status == .ok)
    let spa = "https://\(r.aliceGroup.rawValue).space.test:5530"
    #expect(try await get(r, r.aliceHost, "/x.js", cookie: alices, site: "same-site", mode: "cors", origin: spa).status == .ok)
  }

  @Test func onlyAGroupHostAndTheSPAsItPairsMayFrameIt() async throws {
    let r = try await rig(publicRead: true)
    let csp = HTTPField.Name("Content-Security-Policy")!
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    // The pairs CORS reflects: the --origin ones, then the raw API port's;
    // each the group's, then the bare one.
    let expected = "frame-ancestors 'self' https://\(r.aliceGroup.rawValue).space.test:5530 https://space.test:5530"
      + " https://\(r.aliceGroup.rawValue).space.test:\(Harness.apiPort) https://space.test:\(Harness.apiPort)"
    for path in ["/plan.md", "/_/shell.js", "/nothing-here"] {
      let framed = try await get(r, r.aliceHost, path, cookie: alices, site: "same-site", mode: "navigate")
      #expect(framed.headers[csp] == expected, "\(path)")
    }
    #expect(try await get(r, r.aliceHost, "/plan.md").headers[csp] == expected)
    #expect(try await get(r, "nowhere.space.test:5531", "/plan.md").headers[csp] != nil)
    for path in ["/plan.md", "/_/shell.js", "/_/query?sql=SELECT%201"] {
      #expect(try await get(r, Self.bare, path).headers[csp] == nil, "\(path)")
    }
  }

  // The bare host keeps what it served before groups: the old SPA's
  // cross-port calls and navigations to /_/query with the cookie.
  @Test func theBareHostsCrossPortFlowsStillPass() async throws {
    let r = try await rig()
    let shared = try await cookie(r, r.alice, .shared)
    for path in ["/_/query?sql=SELECT%201", "/_/observe?sql=SELECT%201"] {
      let paired = try await get(r, Self.bare, path, cookie: shared, site: "same-site", mode: "cors", origin: Self.origin)
      #expect(paired.status == .ok, "\(path)")
      #expect(paired.headers[.accessControlAllowOrigin] == Self.origin)
    }
    let logout = try await get(
      r, Self.bare, "/_/session", cookie: shared, site: "same-site", mode: "cors", origin: Self.origin, method: .delete,
    )
    #expect(logout.status == .noContent)
    #expect(logout.headers[.setCookie] != nil)

    let other = try await cookie(r, r.alice, .shared)
    for site in ["same-site", "cross-site"] {
      let navigated = try await get(r, Self.bare, "/_/query?sql=SELECT%201", cookie: other, site: site, mode: "navigate")
      #expect(navigated.status == .ok, "\(site)")
    }
    // A shared file is still a subresource anyone signed in may embed.
    #expect(try await get(r, Self.bare, "/plan.md", cookie: other, site: "same-site", mode: "no-cors").status == .ok)
    // A script from elsewhere still gets no cookie-backed query.
    let scripted = try await get(r, Self.bare, "/_/query?sql=SELECT%201", cookie: other, site: "cross-site", mode: "cors", origin: "https://evil.example")
    #expect(scripted.status == .forbidden)
  }

  @Test func corsOnAGroupHostPairsThatGroupsSPAAndTheBareOne() async throws {
    let r = try await rig(publicRead: true)
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let groupSPA = "https://\(r.aliceGroup.rawValue).space.test:5530"
    let directBare = "https://space.test:\(Harness.apiPort)"
    for spa in [groupSPA, Self.origin, directBare] {
      #expect(try await get(r, r.aliceHost, "/plan.md", cookie: alices, origin: spa).headers[.accessControlAllowOrigin] == spa)
    }
    for requester in [
      "https://\(r.bobGroup.rawValue).space.test:5530", "https://\(r.bobGroup.rawValue).space.test:\(Harness.apiPort)",
      "https://space.test:5531", "https://space.test", "https://evil.example", "https://evil.space.test:5530",
    ] {
      #expect(try await get(r, r.aliceHost, "/plan.md", cookie: alices, origin: requester).headers[.accessControlAllowOrigin] == nil, "\(requester)")
    }
    #expect(try await get(r, Self.bare, "/plan.md", origin: groupSPA).headers[.accessControlAllowOrigin] == nil)
    #expect(try await get(r, Self.bare, "/plan.md", origin: Self.origin).headers[.accessControlAllowOrigin] == Self.origin)
  }

  @Test func mintingOnAGroupHostNeedsMembershipAndBindsTheHost() async throws {
    let r = try await rig()
    let spa = "https://\(r.aliceGroup.rawValue).space.test:5530"
    let minted = try await mint(r, r.alice, host: r.aliceHost, origin: spa)
    #expect(minted.status == .noContent)
    #expect(minted.headers[.accessControlAllowOrigin] == spa)
    let cookies = minted.headers[values: .setCookie]
    let read = try #require(cookies.first)
    #expect(read.hasSuffix("; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=43200"))
    #expect(!cookies.contains { $0.contains("Domain") })
    let token = ReadSessionToken(rawValue: String(try #require(read.split(separator: ";").first).dropFirst("wuhu_read=".count)))
    #expect(try await r.harness.space.account(readSession: token, in: r.aliceGroup) == r.alice)
    #expect(try await r.harness.space.account(readSession: token, in: .shared) == nil)
    #expect(try await get(r, r.aliceHost, "/plan.md", cookie: "wuhu_read=" + token.rawValue).status == .ok)

    let foreign = try await mint(r, r.bob, host: r.aliceHost, origin: spa)
    #expect(foreign.status == .forbidden)
    #expect(try await code(foreign) == "groupForbidden")
    #expect(foreign.headers[.setCookie] == nil)
  }

  // The SPA on the bare API origin reaches every group a person reads: it
  // mints that host's cookie, frames its pages and loads its images, and the
  // pairing admits nobody the membership check would not.
  @Test func theBareSPAReachesAGroupHostItsPersonIsAMemberOf() async throws {
    let r = try await rig()
    let minted = try await mint(r, r.alice, host: r.aliceHost, origin: Self.origin)
    #expect(minted.status == .noContent)
    #expect(minted.headers[.accessControlAllowOrigin] == Self.origin)
    let foreign = try await mint(r, r.bob, host: r.aliceHost, origin: Self.origin)
    #expect(foreign.status == .forbidden)
    #expect(try await code(foreign) == "groupForbidden")
    #expect(foreign.headers[.setCookie] == nil)

    try await put(r, r.aliceGroup, "/avatar.png", "png")
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let image = try await get(r, r.aliceHost, "/avatar.png", cookie: alices, site: "same-site", mode: "cors", origin: Self.origin)
    #expect(image.status == .ok)
    #expect(image.headers[.accessControlAllowOrigin] == Self.origin)
    let csp = HTTPField.Name("Content-Security-Policy")!
    #expect(image.headers[csp]?.contains(" \(Self.origin) ") == true)
    for requester in ["https://\(r.bobGroup.rawValue).space.test:5530", "https://evil.example"] {
      let refused = try await get(r, r.aliceHost, "/avatar.png", cookie: alices, site: "cross-site", mode: "cors", origin: requester)
      #expect(refused.status == .forbidden, "\(requester)")
      #expect(try await code(refused) == "crossOrigin")
    }
  }

  @Test func aTossedCookieDoesNotShadowTheHostsOwn() async throws {
    let r = try await rig()
    let tossed = try await cookie(r, r.bob, r.bobGroup)
    let alices = try await cookie(r, r.alice, r.aliceGroup)
    let page = try await get(r, r.aliceHost, "/plan.md", cookie: "\(tossed); \(alices)")
    #expect(page.status == .ok)
    #expect(page.headers[HTTPField.Name("Wuhu-Viewer")!] == r.alice.rawValue)
  }

  @Test func onlyAGroupHostTellsTheShellItsGroup() async throws {
    let r = try await rig(publicRead: true)
    try await put(r, .shared, "/page.html", "<body>hi</body>")
    try await put(r, r.aliceGroup, "/page.html", "<body>hi</body>")
    let script = #"<script type="module" src="/_/shell.js"></script>"#
    let bare = try await get(r, Self.bare, "/page.html")
    let importMap = #"<script type="importmap">{"imports":{"wuhu:space":"/_/space.js"}}</script>"#
    #expect(try await bare.text() == "\(importMap)<body>hi\(script)</body>")
    let grouped = try await get(r, r.aliceHost, "/page.html", cookie: try await cookie(r, r.alice, r.aliceGroup))
    #expect(try await grouped.text() == importMap + #"<body>hi<meta name="wuhu-group" content="\#(r.aliceGroup.rawValue)">\#(script)</body>"#)
  }

  @Test func anUnknownGroupHostIsNotFoundEverywhere() async throws {
    let r = try await rig(publicRead: true)
    for path in ["/plan.md", "/_/shell.js", "/_/query?sql=SELECT%201"] {
      let response = try await get(r, "nowhere.space.test:5531", path)
      #expect(response.status == .notFound, "\(path)")
      #expect(try await code(response) == "unknownGroup")
    }
  }

  @Test func publicReadOpensTheBareHostOnly() async throws {
    let r = try await rig(publicRead: true)
    #expect(try await get(r, Self.bare, "/plan.md").status == .ok)
    #expect(try await get(r, r.aliceHost, "/plan.md").status == .unauthorized)
    #expect(try await get(r, r.aliceHost, "/_/query?sql=SELECT%201").status == .unauthorized)
  }

  func mint(_ rig: Rig, _ account: AccountID, host: String, origin: String) async throws -> Response {
    let key = Curve25519.Signing.PrivateKey()
    _ = try await rig.harness.space.addKey(key.pubkeyLabel, account: account, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let assertion = try AssertionClaims(
      key: key.pubkeyLabel,
      space: try await rig.harness.space.identity().rawValue,
      expiresAt: fixedDate.addingTimeInterval(60),
    ).signed(by: key)
    var request = Request(url: URL(string: "https://\(host)/_/session")!, method: .post)
    request.headers[.authorization] = "Bearer " + assertion.rawValue
    request.headers[.origin] = origin
    return try await rig.harness.web(request)
  }
}
