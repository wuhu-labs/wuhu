import Fetch
import FetchSSE
import Foundation
import HTTPTypes
import JSONValue
import SpaceCore
import SpaceServer
import Testing

@Suite struct ReadWallTests {
  @Test func anonymousContentReadsAreWalledOutsideDev() async throws {
    let providers = ViewProviders(files: ["kanban.html": Data("<html>kanban</html>".utf8)])
    let harness = try Harness(dev: false, views: providers)
    _ = try await harness.direct("write", .object(["path": "/note.md", "content": "secret"]))

    for path in ["/note.md", "/", "/_/query", "/_/observe"] {
      let response = try await harness.get(harness.web, path)
      #expect(response.status == .unauthorized, "\(path)")
      #expect((try await json(response)).code == "unauthorized", "\(path)")
    }
    let head = try await harness.web(Request(url: URL(string: "http://space/note.md")!, method: .head))
    #expect(head.status == .unauthorized)
    #expect(try await head.text() == "")

    let shell = try await harness.get(harness.web, "/_/shell.js")
    #expect(shell.status == .ok)
    let view = try await harness.get(harness.web, "/_/views/kanban")
    #expect(view.status == .ok)
    let preflight = try await harness.web(Request(url: URL(string: "http://space/_/session")!, method: .options))
    #expect(preflight.status == .noContent)
  }

  @Test func aLiveReadSessionCookieAdmitsContentUntilLogoutOrExpiry() async throws {
    let harness = try Harness(dev: false)
    _ = try await harness.direct("write", .object(["path": "/note.md", "content": "secret"]))
    let account = try await harness.space.addAccount(kind: .human, name: "reader")
    let token = try await harness.space.createReadSession(account: account.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))

    let admitted = try await harness.web(cookieGet("/note.md", cookie: "wuhu_read=" + token.rawValue))
    #expect(admitted.status == .ok)
    #expect(try await admitted.text() == "secret")
    // The page worker keys what it keeps by the account the cookie names.
    #expect(admitted.headers[HTTPField.Name("Wuhu-Viewer")!] == account.id.rawValue)
    let query = try await harness.web(cookieGet("/_/query?sql=SELECT%201", cookie: "wuhu_read=" + token.rawValue))
    #expect(query.status == .ok)
    #expect(query.headers[HTTPField.Name("Wuhu-Viewer")!] == account.id.rawValue)
    let observe = try await harness.web(cookieGet("/_/observe?sql=SELECT%201", cookie: "wuhu_read=" + token.rawValue))
    #expect(observe.status == .ok)
    #expect(observe.headers[HTTPField.Name("Wuhu-Viewer")!] == account.id.rawValue)
    for try await _ in observe.sse() { break }

    let garbage = try await harness.web(cookieGet("/note.md", cookie: "wuhu_read=nonsense"))
    #expect(garbage.status == .unauthorized)

    try await harness.space.deleteReadSession(token)
    let afterLogout = try await harness.web(cookieGet("/note.md", cookie: "wuhu_read=" + token.rawValue))
    #expect(afterLogout.status == .unauthorized)

    let expired = try await harness.space.createReadSession(account: account.id, group: .shared, expiresAt: fixedDate)
    let afterExpiry = try await harness.web(cookieGet("/note.md", cookie: "wuhu_read=" + expired.rawValue))
    #expect(afterExpiry.status == .unauthorized)
  }

  @Test func publicReadOpensContentReadsButNeverWrites() async throws {
    let harness = try Harness(dev: false, publicRead: true)
    _ = try await harness.direct("write", .object(["path": "/board.md", "content": "public"]))

    let content = try await harness.get(harness.web, "/board.md")
    #expect(content.status == .ok)
    #expect(try await content.text() == "public")
    let query = try await harness.get(harness.web, "/_/query", query: ["sql": "SELECT 1"])
    #expect(query.status == .ok)

    let write = try await harness.post("write", .object(["path": "/board.md", "content": "defaced"]))
    #expect(write.status == .unauthorized)
    let mint = try await harness.web(Request(url: URL(string: "http://space/_/session")!, method: .post))
    #expect(mint.status == .unauthorized)
    let read = try await harness.post("read", .object(["path": "/board.md"]))
    #expect(read.status == .unauthorized)
  }

  @Test func unauthenticatedAPIRouteMatrix() async throws {
    let harness = try Harness(dev: false)
    let walled: [(HTTPRequest.Method, String)] = [
      (.post, "/v1/tools/read"),
      (.get, "/v1/observe"),
      (.post, "/v1/persona"),
      (.post, "/v1/enroll"),
      (.post, "/v1/enroll/revoke"),
      (.post, "/v1/machine"),
      (.get, "/v1/machine"),
      (.post, "/v1/machine/m1/rotate"),
      (.post, "/v1/machine/m1/revoke"),
      (.post, "/v1/exec"),
      (.get, "/v1/exec"),
      (.post, "/v1/session"),
      (.post, "/v1/conversation/message"),
      (.post, "/v1/watermark"),
      (.get, "/v1/notifications"),
    ]
    for (method, path) in walled {
      let response = try await harness.api(Request(url: URL(string: "http://space\(path)")!, method: method))
      #expect(response.status == .unauthorized, "\(method) \(path)")
      #expect((try await json(response)).code == "unauthorized", "\(method) \(path)")
    }

    let serverInfo = try await harness.get(harness.api, "/v1/server")
    #expect(serverInfo.status == .ok)
    let machineChallenge = try await harness.get(harness.api, "/v1/machine/challenge")
    #expect(machineChallenge.status == .ok)
    let shareLoginChallenge = try await harness.get(harness.api, "/v1/enroll/share-login/challenge")
    #expect(shareLoginChallenge.status == .ok)
    let consume = try await postJSON(harness, "/v1/enroll/consume", .object(["token": "jt_bogus", "pubkey": "k"]))
    #expect((try await json(consume)).code == "tokenInvalid")
    let shareLogin = try await postJSON(harness, "/v1/enroll/share-login", .object([
      "pubkey": "k", "challenge": "slc_bogus", "signature": "sig",
    ]))
    #expect((try await json(shareLogin)).code == "keyInvalid")
    let connect = try await harness.api(Request(url: URL(string: "http://space/v1/machine/connect")!))
    #expect(connect.status.code == 426)
  }

  @Test func theEmbeddedSPAChromeStaysReachableForLogin() async throws {
    let webApp = try #require(WebApp(files: ["index.html": Data("<html>spa</html>".utf8)]))
    let harness = try Harness(dev: false, webApp: webApp)

    let enroll = try await harness.get(harness.api, "/_/enroll")
    #expect(enroll.status == .ok)
    #expect(try await enroll.text() == "<html>spa</html>")
    let root = try await harness.get(harness.api, "/")
    #expect(root.status == .ok)

    let post = try await harness.api(Request(url: URL(string: "http://space/_/enroll")!, method: .post))
    #expect(post.status == .unauthorized)
    let api = try await harness.get(harness.api, "/v1/machine")
    #expect(api.status == .unauthorized)
  }

  @Test func devDropsBothWalls() async throws {
    let harness = try Harness(dev: true)
    _ = try await harness.direct("write", .object(["path": "/note.md", "content": "open"]))

    let content = try await harness.get(harness.web, "/note.md")
    #expect(content.status == .ok)
    let query = try await harness.get(harness.web, "/_/query", query: ["sql": "SELECT 1"])
    #expect(query.status == .ok)
    let tool = try await harness.post("read", .object(["path": "/note.md"]))
    #expect(tool.status == .ok)
    let server = try await harness.get(harness.api, "/v1/server")
    #expect(server.status == .ok)
  }
}

private func cookieGet(_ pathAndQuery: String, cookie: String) -> Request {
  var headers = RequestHeaders()
  headers[.cookie] = cookie
  return Request(url: URL(string: "http://space" + pathAndQuery)!, headers: headers)
}

private func postJSON(_ harness: Harness, _ path: String, _ body: JSONValue) async throws -> Response {
  try await harness.api(Request(
    url: URL(string: "http://space" + path)!,
    method: .post,
    body: .bytes(Data(body.jsonString().utf8), contentType: "application/json"),
  ))
}

private extension JSONValue {
  var code: String? {
    guard case let .object(fields) = self, case let .string(code)? = fields["code"] else { return nil }
    return code
  }
}
