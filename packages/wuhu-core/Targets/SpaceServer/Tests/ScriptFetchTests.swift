import AsyncHTTPClient
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import FetchAsyncHTTPClient
import Foundation
import HTTPTypes
import JSONValue
import class MainHub.Hub
import OrderedCollections
import ServeNIO
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import SpaceTools
import Synchronization
import Testing
import struct WuhuAI.ToolCall

@Suite(.deterministicDependencies) struct ScriptFetchTests {
  @Test func scriptVerifierChecksJWKSClaimsAndPerCallTokensWhileEchoesAreMasked() async throws {
    let identity = try testIdentity()
    let tokens = Mutex<[String]>([])
    let hop = FetchClient { request in
      let auth = try #require(request.headers[.authorization])
      let jwt = String(auth.dropFirst("Bearer ".count))
      try verify(jwt, jwks: identity.key.jwks, audience: "https://backend.test")
      tokens.withLock { $0.append(jwt) }
      var headers = Headers()
      headers[HTTPField.Name("X-Echo")!] = auth
      headers[.setCookie] = "upstream-cookie=yes"
      headers[try #require(HTTPField.Name(jwt))] = "token-in-name"
      return Response(status: Status(code: 200, reasonPhrase: jwt), headers: headers, body: .string(jwt))
    }
    try await withIdentityScript(identity: identity.controller, hop: hop) { rig in
      let output = try await rig.evaluate(#"""
      import { writeText } from "wuhu:space"
      const a = await fetch("https://backend.test:443/q?private=1", { identity: true })
      const b = await fetch("https://backend.test/q", { identity: true })
      const echo = { a: await a.text(), b: Array.from(new Uint8Array(await b.arrayBuffer())), header: a.headers.get("x-echo"), status: a.statusText, cookie: a.headers.get("set-cookie"), name: Array.from(a.headers).find(([name, value]) => value === "token-in-name")[0] }
      await writeText("/echo.json", JSON.stringify(echo), { ifMatch: null })
      result(echo)
      """#)
      #expect(output == .object(["a": "***", "b": .array([42, 42, 42]), "header": "Bearer ***", "status": "***", "cookie": "upstream-cookie=yes", "name": "***"]))
      let stored = try await rig.space.fs(.shared).read("/echo.json").1
      #expect(JSONValue.parse(String(decoding: stored, as: UTF8.self)) == output)
      let sent = tokens.withLock { $0 }
      #expect(sent.count == 2)
      #expect(Set(sent).count == 2)
      for token in sent {
        let claims = try tokenClaims(token)
        #expect(claims["space"] == .string(try await rig.space.identity().rawValue))
        #expect(claims["group"] == "shared")
        #expect(claims["session"] == .string(rig.session.rawValue))
        #expect(claims["sub"] == .string("shared/" + rig.session.rawValue))
        #expect(claims["iat"] == .integer(1_700_000_000))
        #expect(claims["exp"] == .integer(1_700_000_060))
        #expect(claims["jti"]?.stringValue?.isEmpty == false)
        #expect(claims["path"] == nil && claims["viewer"] == nil)
      }
    }
  }

  @Test func omittedAndFalseIdentityKeepTheExistingTransportAndAuthorization() async throws {
    let ordinary = Mutex<[Request]>([])
    let hops = Mutex(0)
    let fetch = FetchClient { request in
      ordinary.withLock { $0.append(request) }
      return Response(status: .ok, body: .string("plain"))
    }
    try await withIdentityScript(identity: try testIdentity().controller, hop: FetchClient { _ in
      hops.withLock { $0 += 1 }
      return Response(status: .ok)
    }, fetch: fetch) { rig in
      let output = try await rig.evaluate(#"""
      result(await (await fetch("http://backend.test")).text() + await (await fetch("http://backend.test", { identity: false, headers: { Authorization: "custom" } })).text())
      """#)
      #expect(output == "plainplain")
      let requests = ordinary.withLock { $0 }
      #expect(requests.count == 2)
      #expect(requests.first?.headers[.authorization] == nil)
      #expect(requests.last?.headers[.authorization] == "custom")
      #expect(hops.withLock { $0 } == 0)
    }
  }

  @Test func invalidOptionsAndAuthorizationConflictAreTypedAndHaveNoEffects() async throws {
    let effects = Mutex(0)
    let transport = FetchClient { _ in
      effects.withLock { $0 += 1 }
      return Response(status: .ok)
    }
    try await withIdentityScript(identity: try testIdentity().controller, hop: transport, fetch: transport) { rig in
      let output = try await rig.evaluate(#"""
      const errors = []
      for (const identity of [null, undefined, "true", 1, {}, []]) {
        try { await fetch("http://backend.test", { identity }) } catch (e) { errors.push(e.code) }
      }
      for (const input of ["http://backend.test", new Request("http://backend.test", { headers: { AUTHORIZATION: "custom" } })]) {
        try { await fetch(input, { identity: true, ...(typeof input === "string" ? { headers: { aUtHoRiZaTiOn: "custom" } } : {}) }) } catch (e) { errors.push(e.code) }
      }
      result(errors)
      """#)
      #expect(output == .array(Array(repeating: .string("invalidArgument"), count: 8)))
      #expect(effects.withLock { $0 } == 0)
    }
  }

  @Test func redirectsKeepTheOriginalOriginOnlyAndDoNotRemint() async throws {
    let seen = Mutex<[Request]>([])
    let identity = try testIdentity()
    let hop = FetchClient { request in
      seen.withLock { $0.append(request) }
      var headers = Headers()
      switch request.url.path {
      case "/start": headers[.location] = "/same"
      case "/same": headers[.location] = "http://other.test:8080/cross"
      case "/cross": headers[.location] = "https://backend.test:443/back"
      default: return Response(status: .ok, body: .string("done"))
      }
      return Response(status: .temporaryRedirect, headers: headers)
    }
    try await withIdentityScript(identity: identity.controller, hop: hop) { rig in
      #expect(try await rig.evaluate(#"result(await (await fetch('https://backend.test/start', { identity: true })).text())"#) == "done")
      let requests = try #require(seen.withLock { $0.count == 4 ? $0 : nil })
      #expect(requests.map { $0.url.absoluteString } == ["https://backend.test/start", "https://backend.test/same", "http://other.test:8080/cross", "https://backend.test:443/back"])
      let auth = try #require(requests.first?.headers[.authorization])
      #expect(requests[1].headers[.authorization] == auth)
      #expect(requests[2].headers[.authorization] == nil)
      #expect(requests[3].headers[.authorization] == auth)
      try verify(String(auth.dropFirst(7)), jwks: identity.key.jwks, audience: "https://backend.test")
    }
  }

  @Test func realHTTPTransportDoesNotFollowRedirectsBehindTheOriginPolicy() async throws {
    let seen = Mutex<[String?]>([])
    let identity = try testIdentity()
    let cross = try await ServeNIOServer.bind(port: 0, handler: { request in
      seen.withLock { $0.append(request.headers[.authorization]) }
      #expect(request.method == .post)
      let body = try await request.body?.text()
      #expect(body == "payload")
      return Response.text("done")
    })
    do {
      let crossPort = try #require(cross.localAddress?.port)
      let first = try await ServeNIOServer.bind(port: 0, handler: { request in
        let auth = try #require(request.headers[.authorization])
        seen.withLock { $0.append(auth) }
        try verify(String(auth.dropFirst(7)), jwks: identity.key.jwks, audience: try #require(fetchOrigin(request.url)))
        var headers = Headers()
        headers[.location] = request.url.path == "/start" ? "/same" : "http://127.0.0.1:\(crossPort)/cross"
        return Response(status: .temporaryRedirect, headers: headers)
      })
      do {
        let port = try #require(first.localAddress?.port)
        // The process binds the hop transport this way (wuhu/Main.swift): a
        // redirect is answered, never followed.
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        do {
          try await withIdentityScript(identity: identity.controller, hop: .asyncHTTPClient(client, timeout: nil)) { rig in
            let output = try await rig.evaluate("result(await (await fetch('http://127.0.0.1:\(port)/start', { identity: true, method: 'POST', body: 'payload' })).text())")
            #expect(output == "done")
            let requests = try #require(seen.withLock { $0.count == 3 ? $0 : nil })
            #expect(requests[0] != nil && requests[0] == requests[1])
            #expect(requests[2] == nil)
          }
          try await client.shutdown()
        } catch { try? await client.shutdown(); throw error }
        await first.shutdown()
      } catch { await first.shutdown(); throw error }
      await cross.shutdown()
    } catch { await cross.shutdown(); throw error }
  }

  @Test func signingFailureIsTypedWithoutFallback() async throws {
    let network = Mutex(0)
    let plain = FetchClient { _ in network.withLock { $0 += 1 }; return Response(status: .ok) }
    let source = #"try { await fetch('http://backend.test', { identity: true }); result('unexpected') } catch (e) { result({ code: e.code, message: e.message }) }"#
    try await withIdentityScript(hop: plain, fetch: plain) { rig in
      let output = try await rig.evaluate(source)
      #expect(output.object?["code"] == "fetchIdentityUnavailable")
      #expect(output.object?["message"]?.stringValue?.contains("could not sign") == true)
    }
    #expect(network.withLock { $0 } == 0)
  }

  @Test func responseBodyFailureIsMaskedBeforeTheScriptCanReuseIt() async throws {
    try await withIdentityScript(identity: try testIdentity().controller, hop: FetchClient { request in
      let jwt = String(try #require(request.headers[.authorization]).dropFirst(7))
      let body = AsyncThrowingStream<Data, any Error> { $0.finish(throwing: EchoError(description: jwt)) }
      return Response(status: .ok, body: .stream(body))
    }) { rig in
      let output = try await rig.evaluate(#"""
      import { writeText, readText } from "wuhu:space"
      try { await fetch("http://backend.test", { identity: true }) } catch (e) {
        await writeText("/error.txt", e.message, { ifMatch: null })
        result((await readText("/error.txt")).content)
      }
      """#)
      #expect(output == "fetch failed: reading the response body failed: ***")
      let data = try await rig.space.fs(.shared).read("/error.txt").1
      #expect(String(decoding: data, as: UTF8.self) == "fetch failed: reading the response body failed: ***")
    }
  }

  @Test func aStalledResponseBodyEndsWithTheFetchWindow() async throws {
    let clock = TestClock()
    let (heads, head) = AsyncStream<Void>.makeStream()
    try await withIdentityScript(identity: try testIdentity().controller, clock: clock, hop: FetchClient { _ in
      head.yield(())
      return Response(status: .ok, body: .stream(AsyncThrowingStream<Data, any Error> { _ in }))
    }) { rig in
      async let output = rig.evaluate(#"""
      try { await fetch("http://backend.test", { identity: true }); result("read") } catch (e) { result(e.message) }
      """#, wait: 120)
      for await _ in heads { break }
      await clock.advance(by: .seconds(60))
      let message = try await output
      #expect(message == "fetch failed: reading the response body failed: transportFailure(kind: Fetch.TransportFailureKind.deadlineExceeded)")
    }
  }

  @Test func exactTransportErrorEchoIsMaskedBeforeConsoleAndScriptUse() async throws {
    try await withIdentityScript(identity: try testIdentity().controller, hop: FetchClient { request in
      throw EchoError(description: try #require(request.headers[.authorization]))
    }) { rig in
      let output = try await rig.evaluate(#"try { await fetch('http://backend.test', { identity: true }) } catch (e) { console.log(e.message); result(e.name === 'TypeError' && e.code === undefined && e.message === 'fetch failed: Bearer ***') }"#)
      #expect(output == .bool(true))
    }
  }
}

private struct EchoError: Error, CustomStringConvertible { let description: String }

struct TestIdentity {
  let key: ServerIdentity
  let controller: IdentityController
}

/// A server identity issuing for itself at `origin`, no directory.
func testIdentity(origin: String = "https://space.test") throws -> TestIdentity {
  let key = try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation)
  let controller = try IdentityController(
    identity: key, origin: origin, store: .init(load: { nil }, save: { _ in }), fetch: FetchClient { _ in Response(status: .forbidden) },
  )
  return TestIdentity(key: key, controller: controller)
}

struct IdentityScriptRig {
  let space: Space
  let session: SessionID
  let executor: ToolExecutor

  func evaluate(_ source: String, wait: Int = 60) async throws -> JSONValue {
    let payload = try await executor.execute(session: session, call: ToolCall(id: UUID().uuidString, name: "run_script", arguments: .object(["source": .string(source), "wait_seconds": .integer(wait)])), state: ToolExecutionState()).payload
    guard case let .script(result) = payload else { Issue.record("unexpected script result: \(payload)"); return .null }
    let first = String(result.output.prefix { $0 != "\n" })
    return JSONValue.parse(first) ?? .string(first)
  }
}

/// A script session whose `fetch(url, {identity: true})` mints through the
/// session gate's `/v1/id-token` with `identity` (none: the typed refusal)
/// and goes out on `hop`; ordinary fetches use `fetch`.
func withIdentityScript(
  identity: IdentityController? = nil,
  clock: TestClock<Duration>? = nil,
  hop: FetchClient? = nil,
  fetch: FetchClient? = nil,
  _ body: (IdentityScriptRig) async throws -> Void,
) async throws {
  try await withSessionDeps {
    try await withDependencies {
      $0.date = .constant(fixedDate)
      if let clock { $0.continuousClock = clock }
      if let fetch { $0.fetch = fetch }
      if let hop { $0.scriptHop = hop }
    } operation: {
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(group: .shared, title: "fetch test", kind: .agent, createdBy: "tester", model: .init(provider: "test", model: "test", effort: "high"))
      let owner = Hub(space: space)
      let scripts = Scripts(owner: owner)
      let rig = IdentityScriptRig(space: space, session: session, executor: SessionRuntime.toolExecutor(owner: owner, scripts: scripts, identity: identity))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await whenCancelled { await scripts.close() } }
        defer { group.cancelAll() }
        try await body(rig)
      }
    }
  }
}

private func verify(_ jwt: String, jwks: JSONValue, audience: String) throws {
  let parts = jwt.split(separator: ".").map(String.init)
  #expect(parts.count == 3)
  let header = try #require(JSONValue.parse(String(decoding: jwtDecode(parts[0]), as: UTF8.self))?.object)
  let jwk = try #require(jwks.object?["keys"]?.array?.first?.object)
  #expect(header["alg"] == "ES256" && header["kid"] == jwk["kid"])
  let point = Data([4]) + (try jwtDecode(#require(jwk["x"]?.stringValue))) + (try jwtDecode(#require(jwk["y"]?.stringValue)))
  let key = try P256.Signing.PublicKey(x963Representation: point)
  #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: jwtDecode(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
  let claims = try tokenClaims(jwt)
  #expect(claims["iss"] == "https://space.test")
  #expect(claims["aud"] == .string(audience))
  #expect(claims["exp"] == .integer(1_700_000_060))
}

private func tokenClaims(_ jwt: String) throws -> OrderedDictionary<String, JSONValue> {
  try #require(JSONValue.parse(String(decoding: jwtDecode(String(jwt.split(separator: ".")[1])), as: UTF8.self))?.object)
}

private func jwtDecode(_ value: String) throws -> Data {
  let raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)))
}
