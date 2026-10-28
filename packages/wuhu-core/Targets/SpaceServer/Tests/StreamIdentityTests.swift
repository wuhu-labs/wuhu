import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
@testable import MainHub
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct StreamIdentityTests {
  @Test func streamsDialWithAMinuteTokenNamingTheSubscriberForTheStreamOrigin() async throws {
    let identity = try testIdentity()
    let dials = Mutex<[Request]>([])
    let hop = FetchClient { request in
      dials.withLock { $0.append(request) }
      return Response(status: .ok, body: .stream(contentType: "text/event-stream", AsyncThrowingStream { $0.finish() }))
    }
    try await withDependencies {
      $0.date = .constant(fixedDate)
      $0.scriptHop = hop
    } operation: {
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(group: .shared, title: "s", kind: .agent, createdBy: "tester", model: .init(provider: "test", model: "test", effort: "high"))
      let sources = EventSources.signed(by: identity.controller, in: space)
      let url = try #require(URL(string: "https://feed.test:8443/events?topic=a"))
      _ = try await sources.open(url, as: .session(session), after: "41")
      _ = try await sources.open(url, as: .group(.shared), after: "")
      let sent = dials.withLock { $0 }
      try #require(sent.count == 2)
      #expect(sent.map(\.url) == [url, url])
      #expect(sent.map { $0.headers["Last-Event-ID"] } == ["41", nil])
      let claims = try sent.map { request in
        let jwt = try String(#require(request.headers.sensitiveValues["authorization"]).dropFirst("Bearer ".count))
        try verify(jwt, jwks: identity.key.jwks, audience: "https://feed.test:8443")
        return try tokenClaims(jwt)
      }
      #expect(claims.map { $0["sub"] } == [.string("shared/" + session.rawValue), "shared"])
      #expect(claims.map { $0["session"] } == [.string(session.rawValue), nil])
    }
  }
}
