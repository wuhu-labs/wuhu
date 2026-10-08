import Assertion
import Crypto
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct FlatContentHostTests {
  let origin = "https://alex.wuhu.test:5530"
  let pattern = "{group}--alex.wuhu.test"

  @Test(arguments: [
    "alex.wuhu.test", "pre{group}--alex.test", "{group}--{group}.test", "{group}",
    "{group}--alex..test", "{group}--alex.test/path", "{group}--alex.test?x=1",
    "{group}--alex.test#x", "{group}--alex.test:443", "{group}--alex_.test",
    "{group}--alex-.test", "{group}@alex.test", "{group}--" + String(repeating: "a", count: 60) + ".test",
  ]) func rejectsInvalidPatterns(_ pattern: String) {
    #expect(ContentHostPattern(pattern, origin: URL(string: origin)!) == nil)
  }

  @Test func matchingAndPort() throws {
    let host = try #require(ContentHost(origin: origin, pattern: pattern))
    #expect(host.pattern?.template == "{group}--alex.wuhu.test:5530")
    #expect(host.plane(of: "SHARED--ALEX.WUHU.TEST.") == .content(.shared))
    #expect(host.plane(of: "bird-sky--alex.wuhu.test") == .content(GroupID(rawValue: "bird-sky")))
    #expect(host.plane(of: "alex.wuhu.test") == .api)
    for name in [nil, "--alex.wuhu.test", "a.b--alex.wuhu.test", "a_--alex.wuhu.test", "-a--alex.wuhu.test", "a---alex.wuhu.test", "xn----alex.wuhu.test", "xn--foo--alex.wuhu.test", "ab--cd--alex.wuhu.test", "shared--bob.wuhu.test", "shared.alex.wuhu.test", String(repeating: "a", count: 60) + "--alex.wuhu.test"] {
      #expect(host.plane(of: name) == .misdirected)
    }
    #expect(ContentHostPattern("{group}--alex.wuhu.test:5530", origin: URL(string: origin)!)?.template == "{group}--alex.wuhu.test:5530")
  }

  @Test func discoveryRoutingAndMisdirection() async throws {
    let h = try Harness(dev: true, origin: origin, contentHostPattern: pattern)
    _ = try await h.direct("write", .object(["path": "/plan.md", "content": "shared plan"]))
    let account = try await h.space.addAccount(kind: .human, name: "alice").id
    let group = try await h.space.ensurePersonalGroup(account: account)
    _ = try await h.space.fs(group).write("/plan.md", Data("alice plan".utf8), ifMatch: nil)
    let info = try await json(h.api(Request(url: URL(string: origin + "/v1/server")!)))
    #expect(info.object?["contentHost"] == "{group}--alex.wuhu.test:5530")
    #expect(info.object?["contentBase"] == nil)
    for (label, text) in [("shared", "shared plan"), (group.rawValue, "alice plan")] {
      let page = try await h.api(Request(url: URL(string: "https://\(label)--alex.wuhu.test:5530/plan.md")!))
      #expect(try await page.text() == text)
    }
    for host in ["shared.alex.wuhu.test", "shared--bob.wuhu.test", "localhost", "a.b--alex.wuhu.test", "xn----alex.wuhu.test", "xn--foo--alex.wuhu.test", "ab--cd--alex.wuhu.test"] {
      #expect(try await h.api(Request(url: URL(string: "https://\(host):5530/v1/server")!)).status == .misdirectedRequest)
    }
  }

  @Test func accountNamesCannotChooseReservedGroupLabels() async throws {
    let h = try Harness(dev: true, origin: origin, contentHostPattern: pattern)
    let parsed = try #require(ContentHostPattern(pattern, origin: URL(string: origin)!))
    for name in ["xn--", "xn--foo", "ab--cd"] {
      let account = try await h.space.addAccount(kind: .human, name: name).id
      let group = try await h.space.ensurePersonalGroup(account: account)
      #expect(group.rawValue != name)
      #expect(group.rawValue.split(separator: "-").count == 3)
      #expect(parsed.group(host: group.rawValue + "--alex.wuhu.test") == group)
      #expect(parsed.group(host: name + "--alex.wuhu.test") == nil)
    }
  }

  @Test func smartBannerUsesTheFlatTemplate() async throws {
    let shell = WebApp(files: ["index.html": Data("<html><head></head></html>".utf8)])!
    let h = try Harness(dev: true, origin: origin, contentHostPattern: pattern, webApp: shell)
    let page = try await h.api(Request(url: URL(string: origin + "/plan.md?group=bird-sky&q=1")!))
    #expect(try await page.text().contains("app-argument=wuhu://bird-sky--alex.wuhu.test:5530/plan.md?q=1"))
  }

  @Test func flatCookiesMintReadEveryDuplicateAndClear() async throws {
    let h = try Harness(dev: false, origin: origin, contentHostPattern: pattern)
    _ = try await h.direct("write", .object(["path": "/plan.md", "content": "secret"]))
    let account = try await h.space.addAccount(kind: .human, name: "alice").id
    let key = Curve25519.Signing.PrivateKey()
    _ = try await h.space.addKey(key.pubkeyLabel, account: account, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let assertion = try AssertionClaims(key: key.pubkeyLabel, space: try await h.space.identity().rawValue, expiresAt: fixedDate.addingTimeInterval(60)).signed(by: key)
    let base = "https://shared--alex.wuhu.test:5530"
    var request = Request(url: URL(string: base + "/_/session")!, method: .post)
    request.headers[.authorization] = "Bearer " + assertion.rawValue
    let minted = try await h.api(request)
    #expect(minted.status == .noContent)
    let cookies = minted.headers.filter { $0.name == .setCookie }.map(\.value)
    #expect(cookies.count == 2)
    #expect(cookies[0].hasPrefix("__Host-wuhu_read="))
    #expect(cookies[0].contains("Path=/; HttpOnly; Secure; SameSite=Lax"))
    #expect(cookies[1].hasPrefix("__Host-wuhu_viewer="))
    #expect(cookies.allSatisfy { !$0.contains("Domain=") })
    let cookie = String(cookies[0].split(separator: ";")[0])
    var get = Request(url: URL(string: base + "/plan.md")!)
    get.headers[.cookie] = "__Host-wuhu_read=bad; " + cookie
    #expect(try await h.api(get).status == .ok)
    get.headers[.cookie] = cookie.replacingOccurrences(of: "__Host-", with: "")
    #expect(try await h.api(get).status == .unauthorized)
    var end = Request(url: URL(string: base + "/_/session")!, method: .delete)
    end.headers[.cookie] = cookie
    let cleared = try await h.api(end)
    let clearing = cleared.headers.filter { $0.name == .setCookie }.map(\.value)
    #expect(clearing == ["__Host-wuhu_read=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0", "__Host-wuhu_viewer=; Path=/; Secure; SameSite=Lax; Max-Age=0"])
    get.headers[.cookie] = cookie
    #expect(try await h.api(get).status == .unauthorized)
  }

  @Test func flatPageWritesAdmitOnlyTheHostCookie() async throws {
    let h = try Harness(dev: false, origin: origin, contentHostPattern: pattern)
    let account = try await h.space.addAccount(kind: .human, name: "alice").id
    let written = try await h.direct("write", .object(["path": "/plan.md", "content": "---\nk: 1\n---\n"]))
    let token = try await h.space.createReadSession(account: account, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    let base = "https://shared--alex.wuhu.test:5530"
    func patch(_ cookie: String, _ ifMatch: JSONValue?) async throws -> Response {
      var request = Request(url: URL(string: base + "/_/space/attributes")!, method: .post)
      request.headers[.origin] = base
      request.headers[HTTPField.Name("Sec-Fetch-Site")!] = "same-origin"
      request.headers[.contentType] = "application/json"
      request.headers[.cookie] = cookie
      request.body = .string(JSONValue.object(["path": "/plan.md", "set": .object(["k": 2]), "ifMatch": ifMatch ?? .null, "page": "/p.html"]).jsonString())
      return try await h.api(request)
    }
    #expect(try await patch("wuhu_read=" + token.rawValue, written.object?["token"]).status == .unauthorized)
    #expect(try await patch("__Host-wuhu_read=" + token.rawValue, written.object?["token"]).status == .ok)
  }
}
