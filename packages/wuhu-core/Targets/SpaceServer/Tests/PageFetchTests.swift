import Crypto
import Dependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import NIOCore
import NIOPosix
import OrderedCollections
import Serve
import ServeNIO
import SpaceContract
import SpaceCore
@testable import SpaceServer
import SpaceTools
import Synchronization
import Testing

@Suite struct PageFetchTests {
  struct Rig {
    let h: Harness
    let cookie: String
    let viewer: String
    let account: String
  }

  func rig(proxy: PageFetch, publicRead: Bool = false) async throws -> Rig {
    let h = try Harness(dev: false, publicRead: publicRead, origin: "https://space.test", pageFetch: proxy.response, identityJWKS: proxy.identity.jwks)
    let account = try await h.space.addAccount(kind: .human, name: "alice", admin: true).id
    let persona = try await h.space.persona(account: account)?.name ?? account.rawValue
    let token = try await h.space.createReadSession(account: account, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    return Rig(h: h, cookie: "wuhu_read=" + token.rawValue, viewer: persona, account: account.rawValue)
  }

  func identity() throws -> ServerIdentity { try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation) }

  func list(_ rig: Rig, _ content: String) async throws {
    let token = try? await rig.h.direct("read", ["path": "/fetch.json"]).object?["token"]
    var input: OrderedDictionary<String, JSONValue> = ["path": "/fetch.json", "content": .string(content)]
    if let token { input["ifMatch"] = token }
    // The tool context records its read and guards an overwrite.
    _ = try await rig.h.direct("write", .object(input))
  }

  func request(_ rig: Rig, url: String = "http://backend.test/q", headers: [String: String] = [:], authenticated: Bool = true, body: Data = Data(), method: String = "POST", page: String = "/dash.html") async throws -> Response {
    var parts = URLComponents(string: "https://shared.space.test/_/space/fetch")!
    parts.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "page", value: page), URLQueryItem(name: "method", value: method), URLQueryItem(name: "headers", value: JSONValue.object(OrderedDictionary(uniqueKeysWithValues: headers.map { ($0.key, .string($0.value)) })).jsonString())]
    var fields = Headers()
    fields[.origin] = "https://shared.space.test"
    fields[HTTPField.Name("Sec-Fetch-Site")!] = "same-origin"
    if authenticated { fields[.cookie] = rig.cookie }
    return try await rig.h.web(Request(url: parts.url!, method: .post, headers: fields, body: .bytes(body)))
  }

  @Test func refusalsAreTypedAndListEditsAreImmediate() async throws {
    let calls = Mutex(0)
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in
      calls.withLock { $0 += 1 }
      return Response.text("ok")
    })
    let r = try await rig(proxy: proxy, publicRead: true)
    for content in [nil, "", #"{"allow":[]}"#] {
      if let content { try await list(r, content) }
      let response = try await request(r)
      #expect(response.status == .forbidden)
      let error = try await json(response)
      #expect(error.object?["code"] == "fetchListMissing")
      #expect(error.object?["message"]?.stringValue?.contains("/fetch.json") == true)
    }
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    let denied = try await request(r, url: "http://unlisted.test")
    #expect(try await json(denied).object?["code"] == "fetchOriginForbidden")
    let auth = try await request(r, headers: ["AuThOrIzAtIoN": "secret"])
    #expect(try await json(auth).object?["code"] == "fetchAuthorizationForbidden")
    let anonymous = try await request(r, authenticated: false)
    #expect(try await json(anonymous).object?["code"] == "fetchViewerRequired")
    #expect(calls.withLock { $0 } == 0)
    #expect(try await request(r).status == .ok)
    try await list(r, #"{"allow":["http://other.test"]}"#)
    #expect(try await request(r).status == .forbidden)
    #expect(try await request(r, url: "http://other.test").status == .ok)
    #expect(calls.withLock { $0 } == 2)
  }

  @Test func redirectsRequireListedOriginAndMintNewAudience() async throws {
    let seen = Mutex<[Request]>([])
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { request, _ in
      seen.withLock { $0.append(request) }
      if request.url.host == "backend.test" {
        var fields = Headers()
        fields[.location] = "http://redirect.test/final"
        return Response(status: .temporaryRedirect, headers: fields)
      }
      return Response.text("done")
    })
    let r = try await rig(proxy: proxy)
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    let denied = try await request(r)
    #expect(try await json(denied).object?["code"] == "fetchOriginForbidden")
    #expect(seen.withLock { $0.count } == 1)
    try await list(r, #"{"allow":["http://backend.test","http://redirect.test"]}"#)
    let response = try await request(r, body: Data("query".utf8))
    #expect(try await response.text() == "done")
    let last = try #require(seen.withLock { $0.last })
    #expect(last.method == .post)
    #expect(try await last.body?.text() == "query")
    let claims = try jwtClaims(last.headers[.authorization]!)
    #expect(claims.object?["aud"] == "http://redirect.test")
    #expect(claims.object?["viewer"] == .string(r.viewer))
  }

  @Test func localBackendVerifiesTokenAgainstDiscoveryAndReceivesNoCookies() async throws {
    let identity = try identity()
    let seen = Mutex<[Request]>([])
    let seenBodies = Mutex<[String?]>([])
    let jwk = try #require(identity.jwks.object?["keys"]?.array?.first?.object)
    let point = Data([4]) + (try decode(#require(jwk["x"]?.stringValue))) + (try decode(#require(jwk["y"]?.stringValue)))
    let publicKey = try P256.Signing.PublicKey(x963Representation: point)
    let server = try await ServeNIOServer.bind(port: 0, handler: { request in
      let body = try await request.body?.text()
      seenBodies.withLock { $0.append(body) }
      let authorization = try #require(request.headers[.authorization])
      let parts = authorization.dropFirst("Bearer ".count).split(separator: ".").map(String.init)
      let claims = try jwtClaims(authorization)
      guard claims.object?["aud"] == .string(fetchOrigin(request.url)!), claims.object?["iss"] == "https://space.test",
            (claims.object?["exp"]?.intValue ?? 0) > Int(Date().timeIntervalSince1970),
            try publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8))
      else { return Response(status: .unauthorized) }
      seen.withLock { $0.append(request) }
      var headers = Headers()
      headers[.setCookie] = "backend=secret"
      headers[HTTPField.Name("X-Backend")!] = "yes"
      return Response(status: .unprocessableContent, headers: headers, body: .string("backend result"))
    })
    do {
      let port = try #require(server.localAddress?.port)
      let origin = "http://dashboard.invalid:\(port)"
      let resolutions = Mutex(0)
      let proxy = PageFetch(identity: identity, issuer: "https://space.test", hop: { request, deadline in
        try await pinnedPageFetch(request, deadline: deadline, resolve: { host, port in
          #expect(host == "dashboard.invalid")
          resolutions.withLock { $0 += 1 }
          return try SocketAddress(ipAddress: "127.0.0.1", port: port)
        })
      })
      let r = try await rig(proxy: proxy)
      try await list(r, #"{"allow":["\#(origin)"]}"#)
      let response = try await request(r, url: origin + "/query", headers: ["Cookie": "smuggle=secret", "Host": "attacker", "Content-Type": "text/plain", "X-Query": "yes"], body: Data("select 1".utf8))
      #expect(response.status == .unprocessableContent)
      #expect(response.headers[.setCookie] == nil)
      #expect(response.headers[HTTPField.Name("Wuhu-Fetch-Result")!] == "upstream")
      #expect(try await response.text() == "backend result")
      let upstream = try #require(seen.withLock { $0.first })
      #expect(upstream.headers[.cookie] == nil)
      #expect(upstream.url.host == "dashboard.invalid")
      #expect(resolutions.withLock { $0 } == 1)
      #expect(upstream.headers[HTTPField.Name("X-Query")!] == "yes")
      #expect(seenBodies.withLock { $0.first! } == "select 1")
      let token = try #require(upstream.headers[.authorization]?.dropFirst("Bearer ".count))
      let parts = token.split(separator: ".").map(String.init)
      let claims = try jwtClaims("Bearer " + token)
      #expect(claims.object?["iss"] == "https://space.test")
      #expect(claims.object?["aud"] == .string(origin))
      #expect(claims.object?["space"] == .string(try await r.h.space.identity().rawValue))
      #expect(claims.object?["group"] == "shared")
      #expect(claims.object?["path"] == "/dash.html")
      #expect(claims.object?["viewer"] == .string(r.viewer))
      #expect(claims.object?["exp"]?.intValue == (claims.object?["iat"]?.intValue ?? 0) + 60)
      let jwks = try await json(r.h.api(Request(url: URL(string: "https://space.test/.well-known/jwks.json")!)))
      let jwk = try #require(jwks.object?["keys"]?.array?.first?.object)
      let header = JSONValue.parse(String(decoding: try decode(parts[0]), as: UTF8.self))
      #expect(header?.object?["kid"] == jwk["kid"])
      let point = Data([4]) + (try decode(#require(jwk["x"]?.stringValue))) + (try decode(#require(jwk["y"]?.stringValue)))
      let key = try P256.Signing.PublicKey(x963Representation: point)
      #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func directoryPageAndTrailingSlashOriginAreAcceptedAndViewerIsTrusted() async throws {
    let seen = Mutex<[Request]>([])
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { request, _ in
      seen.withLock { $0.append(request) }
      var fields = Headers()
      fields[.init("Wuhu-Viewer")!] = "another-account"
      return Response(status: .ok, headers: fields)
    })
    let r = try await rig(proxy: proxy)
    try await list(r, #"{"allow":["http://backend.test/"]}"#)
    let response = try await request(r, page: "/dashboards/")
    #expect(response.status == .ok)
    #expect(response.headers[.init("Wuhu-Viewer")!] == r.account)
    let upstream = try #require(seen.withLock { $0.first })
    #expect(try jwtClaims(upstream.headers[.authorization]!).object?["path"] == "/dashboards")
  }

  @Test func redirect303BecomesGetAndRedirectLoopStopsAfterTwentyHops() async throws {
    let seen = Mutex<[Request]>([])
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { request, _ in
      seen.withLock { $0.append(request) }
      if request.url.path == "/q" {
        var fields = Headers()
        fields[.location] = "/final"
        return Response(status: .seeOther, headers: fields)
      }
      return Response.text("final")
    })
    let r = try await rig(proxy: proxy)
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    #expect(try await request(r, headers: ["Content-Type": "text/plain"], body: Data("query".utf8)).status == .ok)
    let redirected = try #require(seen.withLock { $0.last })
    #expect(redirected.method == .get)
    #expect(redirected.body == nil)
    #expect(redirected.headers[.contentType] == nil)
    let count = Mutex(0)
    let looping = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in
      count.withLock { $0 += 1 }
      var fields = Headers()
      fields[.location] = "/q"
      return Response(status: .temporaryRedirect, headers: fields)
    })
    let loopRig = try await rig(proxy: looping)
    try await list(loopRig, #"{"allow":["http://backend.test"]}"#)
    let denied = try await request(loopRig)
    #expect(denied.status == .badGateway)
    #expect(try await json(denied).object?["code"] == "fetchRedirectInvalid")
    #expect(count.withLock { $0 } == 21)
  }

  @Test func upstreamTimeoutAndIdentityFailuresKeepTheirTypedClassification() async throws {
    for timeout in [true, false] {
      let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in
        if timeout { throw PageFetchError.timeout }
        throw FetchTestFailure.unavailable
      })
      let r = try await rig(proxy: proxy)
      try await list(r, #"{"allow":["http://backend.test"]}"#)
      let denied = try await request(r)
      #expect(denied.status == (timeout ? .gatewayTimeout : .badGateway))
      #expect(try await json(denied).object?["code"] == .string(timeout ? "fetchTimeout" : "fetchUpstreamUnavailable"))
    }
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in Issue.record("identity failure must not connect"); return Response.text("bad") })
    let r = try await rig(proxy: proxy)
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    var fields = Headers()
    fields[.origin] = "https://shared.space.test"
    fields[.init("Sec-Fetch-Site")!] = "same-origin"
    fields[.cookie] = r.cookie
    let denied = await withDependencies { $0.date = .constant(fixedDate); $0.continuousClock = ContinuousClock() } operation: {
      await pageFetchResponse(
        space: r.h.space,
        caller: WebCaller(group: .shared, crossOrigin: false, contentOrigins: ["https://shared.space.test"], cookies: .legacy),
        proxy: proxy.response,
        request: Request(url: URL(string: "https://shared.space.test/_/space/fetch?url=http%3A%2F%2Fbackend.test&page=%2Fdash.html")!, method: .post, headers: fields),
        spaceIdentity: { _ in throw FetchTestFailure.unavailable },
      )
    }
    #expect(denied.status == .serviceUnavailable)
    #expect(try await json(denied).object?["code"] == "fetchIdentityUnavailable")
  }

  @Test func anotherGroupsAllowListAndExecBearerCannotAdmitFetch() async throws {
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in Issue.record("must not connect"); return Response.text("bad") })
    let r = try await rig(proxy: proxy)
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    let account = try await r.h.space.addAccount(kind: .human, name: "bob").id
    let group = try await r.h.space.ensurePersonalGroup(account: account)
    let token = try await r.h.space.createReadSession(account: account, group: group, expiresAt: fixedDate.addingTimeInterval(3600))
    var url = URLComponents(string: "https://\(group.rawValue).space.test/_/space/fetch")!
    url.queryItems = [URLQueryItem(name: "url", value: "http://backend.test"), URLQueryItem(name: "page", value: "/dash.html")]
    var headers = Headers()
    headers[.origin] = "https://\(group.rawValue).space.test"
    headers[HTTPField.Name("Sec-Fetch-Site")!] = "same-origin"
    headers[.cookie] = "wuhu_read=" + token.rawValue
    headers[HTTPField.Name("Wuhu-Group")!] = "shared"
    let other = try await r.h.api(Request(url: url.url!, method: .post, headers: headers))
    #expect(try await json(other).object?["code"] == "fetchListMissing")
    headers[.cookie] = nil
    headers[.authorization] = "Bearer wst_fake_exec_token"
    let exec = try await r.h.api(Request(url: url.url!, method: .post, headers: headers))
    #expect(try await json(exec).object?["code"] == "fetchViewerRequired")
    headers[.cookie] = "wuhu_read=" + token.rawValue
    headers[.origin] = "https://shared.space.test"
    let sibling = try await r.h.api(Request(url: url.url!, method: .post, headers: headers))
    #expect(try await json(sibling).object?["code"] == "crossOrigin")
  }

  @Test func tricklingInboundUploadTimesOutAndClosesWithoutKeepAliveDrain() async throws {
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in
      Issue.record("an incomplete upload must not reach the backend")
      return Response.text("bad")
    })
    let r = try await rig(proxy: proxy)
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    let caller = WebCaller(group: .shared, crossOrigin: false, contentOrigins: ["https://shared.space.test"], cookies: .legacy)
    let server = try await ServeNIOServer.bind(port: 0, handler: { request in
      await withDependencies {
        $0.continuousClock = ContinuousClock()
        $0.date = .constant(fixedDate)
      } operation: {
        await pageFetchResponse(space: r.h.space, caller: caller, proxy: proxy.response, request: request, deadline: .now() + .milliseconds(250))
      }
    })
    let received = FetchWireResponse()
    let port = try #require(server.localAddress?.port)
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelInitializer { $0.pipeline.addHandler(received) }
      .connect(host: "127.0.0.1", port: port).get()
    do {
      let head = "POST /_/space/fetch?url=http%3A%2F%2Fbackend.test%2Fq&page=%2Fdash.html&method=POST HTTP/1.1\r\nHost: shared.space.test\r\nOrigin: https://shared.space.test\r\nSec-Fetch-Site: same-origin\r\nCookie: \(r.cookie)\r\nContent-Length: 1048576\r\n\r\nx"
      try await channel.writeAndFlush(ByteBuffer(string: head)).get()
      let started = ContinuousClock.now
      let limit = started + .seconds(2)
      while !received.inactive && ContinuousClock.now < limit {
        try await ContinuousClock().sleep(for: .milliseconds(40))
        if !received.inactive { try? await channel.writeAndFlush(ByteBuffer(string: "x")).get() }
      }
      #expect(received.text.contains("HTTP/1.1 504"))
      #expect(received.text.contains("fetchTimeout"))
      #expect(received.inactive)
      #expect(ContinuousClock.now - started < .seconds(2))
      try? await channel.close().get()
      await server.shutdown()
    } catch {
      try? await channel.close().get()
      await server.shutdown()
      throw error
    }
  }

  @Test func streamingResponseIsNotCollectedAndTotalDeadlineClosesIt() async throws {
    let server = try await ServeNIOServer.bind(port: 0, handler: { _ in
      Response(status: .ok, body: .stream(SlowFetchBody()))
    })
    do {
      let port = try #require(server.localAddress?.port)
      let response = try await pinnedPageFetch(Request(url: URL(string: "http://127.0.0.1:\(port)/stream")!), deadline: .now() + .seconds(5))
      #expect(response.status == .ok)
      var iterator = response.body.asyncBytes().makeAsyncIterator()
      #expect(try await iterator.next() == Data("first".utf8))
      await #expect(throws: (any Error).self) { try await iterator.next() }
      await server.shutdown()
    } catch { await server.shutdown(); throw error }
  }

  @Test func requestLimitAndInvalidListAreTyped() async throws {
    let proxy = PageFetch(identity: try identity(), issuer: "https://space.test", hop: { _, _ in Issue.record("must not connect"); return Response.text("bad") })
    let r = try await rig(proxy: proxy)
    for entry in ["https://*.test", "https://backend.test/path", "https://user:pass@backend.test", "ftp://backend.test"] {
      try await list(r, #"{"allow":["\#(entry)"]}"#)
      #expect(try await json(request(r)).object?["code"] == "fetchListInvalid")
    }
    try await list(r, #"{"allow":["http://backend.test"]}"#)
    #expect(try await json(request(r, body: Data(repeating: 0, count: (10 << 20) + 1))).object?["code"] == "fetchBodyTooLarge")
    #expect(try await json(request(r, method: "OPTIONS")).object?["code"] == "fetchMethodInvalid")
  }
}

private func jwtClaims(_ bearer: String) throws -> JSONValue {
  let token = bearer.dropFirst("Bearer ".count)
  return try #require(JSONValue.parse(String(decoding: decode(String(token.split(separator: ".")[1])), as: UTF8.self)))
}

private func decode(_ text: String) throws -> Data {
  let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
}

private struct SlowFetchBody: AsyncSequence, Sendable {
  typealias Element = Bytes
  func makeAsyncIterator() -> Iterator { Iterator() }
  struct Iterator: AsyncIteratorProtocol {
    var first = true
    mutating func next() async throws -> Bytes? {
      if first { first = false; return Data("first".utf8) }
      try await ContinuousClock().sleep(for: .seconds(60))
      return nil
    }
  }
}

private final class FetchWireResponse: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer
  private struct State { var text = ""; var inactive = false }
  private let state = Mutex(State())
  var text: String { state.withLock { $0.text } }
  var inactive: Bool { state.withLock { $0.inactive } }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    let chunk = buffer.readString(length: buffer.readableBytes) ?? ""
    state.withLock { $0.text += chunk }
  }

  func channelInactive(context: ChannelHandlerContext) {
    state.withLock { $0.inactive = true }
    context.fireChannelInactive()
  }
}

private enum FetchTestFailure: Error { case unavailable }
