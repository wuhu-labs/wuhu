import Clocks
import Crypto
import Dependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import NIOCore
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite struct ScriptFetchPolicyTests {
  @Test func ordinaryCallMasksHeaderNamesContainingAnEarlierIdentityToken() async throws {
    let token = Mutex<String?>(nil)
    let proxy = ScriptFetch(identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), issuer: "https://space.test", hop: { request, _ in
      token.withLock { $0 = request.headers[.authorization].map { String($0.dropFirst(7)) } }
      return Response.text("ok")
    })
    let plain = FetchClient { _ in
      var headers = Headers()
      let jwt = try #require(token.withLock { $0 })
      headers[try #require(HTTPField.Name(jwt))] = "echo"
      return Response(status: .ok, headers: headers)
    }
    try await withIdentityScript(proxy: proxy, fetch: plain) { rig in
      let output = try await rig.evaluate(#"""
      import { writeText } from "wuhu:space"
      await fetch("http://backend.test", { identity: true })
      const response = await fetch("http://backend.test/echo")
      const name = Array.from(response.headers).find(([name, value]) => value === "echo")[0]
      await writeText("/header.txt", name, { ifMatch: null })
      result(name)
      """#)
      #expect(output == "***")
      let stored = try await rig.space.fs(.shared).read("/header.txt").1
      #expect(String(decoding: stored, as: UTF8.self) == "***")
    }
  }

  @Test(arguments: [301, 302, 303, 307, 308], ["POST", "PUT", "GET", "HEAD"])
  func redirectMethodBodyAndContentHeaderPolicy(status: Int, method: String) async throws {
    let seen = Mutex<[Hop]>([])
    let proxy = ScriptFetch(identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), issuer: "https://space.test", hop: { request, _ in
      let body = try await request.body?.text()
      seen.withLock { $0.append(Hop(method: request.method.rawValue, body: body, headers: request.headers.fields)) }
      guard request.url.path == "/start" else { return Response.text("done") }
      var headers = Headers()
      headers[.location] = "/final"
      return Response(status: Status(code: status), headers: headers)
    })
    try await withIdentityScript(proxy: proxy) { rig in
      let bodyless = method == "HEAD" || method == "GET"
      let body = bodyless ? "" : ", body: 'payload'"
      let output = try await rig.evaluate("result(await (await fetch('http://backend.test/start', { identity: true, method: '\(method)', headers: { 'Content-Type': 'text/plain', 'Content-Length': '\(bodyless ? 0 : 7)' }\(body) })).text())")
      #expect(output == "done")
      let hops = try #require(seen.withLock { $0.count == 2 ? $0 : nil })
      let rewritten = ([301, 302].contains(status) && method == "POST") || (status == 303 && method != "HEAD")
      #expect(hops[0].method == method)
      #expect(hops[1].method == (rewritten ? "GET" : method))
      #expect(hops[1].body == (rewritten || bodyless ? nil : "payload"))
      #expect(hops[1].headers[.contentType] == (rewritten ? nil : "text/plain"))
      #expect(hops[1].headers[.contentLength] == (rewritten ? nil : bodyless ? "0" : "7"))
      #expect(hops[0].headers[.authorization] == hops[1].headers[.authorization])
    }
  }

  @Test(arguments: ["/cycle", "ftp://other.test/invalid", "http://user:secret@other.test/invalid"])
  func redirectBoundAndInvalidDestinationsAreOrdinaryFetchErrors(location: String) async throws {
    let calls = Mutex(0)
    let proxy = ScriptFetch(identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), issuer: "https://space.test", hop: { _, _ in
      calls.withLock { $0 += 1 }
      var headers = Headers()
      headers[.location] = location
      return Response(status: .temporaryRedirect, headers: headers)
    })
    try await withIdentityScript(proxy: proxy) { rig in
      let output = try await rig.evaluate(#"try { await fetch('http://backend.test/start', { identity: true }); result('unexpected') } catch (e) { result({ name: e.name, code: e.code ?? null, message: e.message }) }"#)
      #expect(output == .object(["name": "TypeError", "code": .null, "message": "fetch failed: invalidRedirect"]))
      #expect(calls.withLock { $0 } == (location == "/cycle" ? 21 : 1))
    }
  }

  @Test(arguments: ["dns", "transport", "timeout"])
  func upstreamFailuresKeepOrdinaryFetchErrorBehavior(kind: String) async throws {
    let failure: any Error = switch kind {
    case "timeout": FetchError.transportFailure(kind: .deadlineExceeded)
    case "transport": FetchError.transportFailure(kind: .connectionClosed)
    default: DNSFailure()
    }
    let plainCalls = Mutex(0)
    let proxy = ScriptFetch(identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), issuer: "https://space.test", hop: { request, deadline in
      if kind == "dns" {
        return try await pinnedPageFetch(request, deadline: deadline, resolve: { _, _ in throw failure })
      }
      throw failure
    })
    let plain = FetchClient { _ in plainCalls.withLock { $0 += 1 }; throw failure }
    try await withIdentityScript(proxy: proxy, fetch: plain) { rig in
      let output = try await rig.evaluate(#"""
      const errors = []
      for (const init of [{ identity: true }, {}]) {
        try { await fetch("http://backend.test", init) } catch (e) { errors.push({ name: e.name, code: e.code ?? null, message: e.message }) }
      }
      result(errors)
      """#)
      let errors = try #require(output.array)
      #expect(errors.count == 2)
      #expect(errors[0] == errors[1])
      #expect(errors[0].object?["name"] == "TypeError")
      #expect(errors[0].object?["code"] == .null)
      #expect(plainCalls.withLock { $0 } == 1)
    }
  }

  @Test(arguments: [0, 20])
  func totalDeadlineBoundsSlowDNSAcrossRedirects(firstHopSeconds: Int) async throws {
    try await withSessionDeps {
      let clock = TestClock()
      try await withDependencies { $0.continuousClock = clock } operation: {
        let (started, enter) = AsyncStream<Void>.makeStream()
        let seen = Mutex(0)
        let proxy = ScriptFetch(identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), issuer: "https://space.test", hop: { request, deadline in
          seen.withLock { $0 += 1 }
          if firstHopSeconds > 0 && request.url.path == "/start" {
            await clock.advance(by: .seconds(firstHopSeconds))
            var headers = Headers()
            headers[.location] = "/slow"
            return Response(status: .temporaryRedirect, headers: headers)
          }
          return try await pinnedPageFetch(request, deadline: deadline, stripCookies: false, resolve: { _, _ in
            enter.yield()
            @Dependency(\.continuousClock) var resolverClock
            try await resolverClock.sleep(for: .seconds(600))
            Issue.record("DNS must be cancelled before its result connects")
            return try SocketAddress(ipAddress: "127.0.0.1", port: 1)
          })
        })
        let space = try Space.inMemory()
        let session = try await space.sessions.createSession(group: .shared, title: "deadline", kind: .agent, createdBy: "tester", model: .init(provider: "test", model: "test", effort: "high"))
        let initial = clock.now
        let task = Task {
          do {
            _ = try await proxy.response(Request(url: URL(string: "http://backend.test/start")!), session: session, space: space, protect: { _ in })
            Issue.record("slow DNS should time out")
            return Optional<FetchError>.none
          } catch { return error as? FetchError }
        }
        for await _ in started { break }
        await clock.advance(to: initial.advanced(by: .seconds(60)))
        await clock.advance()
        #expect(await task.value == .transportFailure(kind: .deadlineExceeded))
        #expect(initial.duration(to: clock.now) == .seconds(60))
        #expect(seen.withLock { $0 } == (firstHopSeconds == 0 ? 1 : 2))
      }
    }
  }

  @Test func expiredRedirectDoesNotStartAnotherHop() async throws {
    try await withSessionDeps {
      let clock = TestClock()
      try await withDependencies { $0.continuousClock = clock } operation: {
        let seen = Mutex(0)
        let proxy = ScriptFetch(identity: try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation), issuer: "https://space.test", hop: { _, _ in
          seen.withLock { $0 += 1 }
          await clock.advance(by: .seconds(60))
          var headers = Headers()
          headers[.location] = "/after-expiry"
          return Response(status: .temporaryRedirect, headers: headers)
        })
        let space = try Space.inMemory()
        let session = try await space.sessions.createSession(group: .shared, title: "deadline", kind: .agent, createdBy: "tester", model: .init(provider: "test", model: "test", effort: "high"))
        await #expect(throws: FetchError.transportFailure(kind: .deadlineExceeded)) {
          try await proxy.response(Request(url: URL(string: "http://backend.test/start")!), session: session, space: space, protect: { _ in })
        }
        #expect(seen.withLock { $0 } == 1)
      }
    }
  }
}

private struct Hop: Sendable {
  let method: String
  let body: String?
  let headers: Headers
}

private struct DNSFailure: Error, CustomStringConvertible {
  var description: String { "DNS resolution failed" }
}
