import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing

@Suite struct SessionTitleRouteTests {
  @Test func renamingASessionStoresTheTrimmedTitle() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession(title: "I don't know")

      struct Renamed: Decodable { let title: String }
      let renamed = try await harness.call(
        "/v1/session/\(session.rawValue)/title",
        .object(["title": "  Nightly release watch  "]),
        as: Renamed.self,
      )
      #expect(renamed.title == "Nightly release watch")
      #expect(try await harness.store.record(session).title == "Nightly release watch")
    }
  }

  @Test func anUnusableTitleIsRefusedAndChangesNothing() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession(title: "keep me")

      for refused in ["", "two\nlines", String(repeating: "x", count: SessionStore.titleLimit + 1)] {
        let response = try await harness.post(
          "/v1/session/\(session.rawValue)/title", .object(["title": .string(refused)]),
        )
        #expect(response.status == .unprocessableContent)
      }
      #expect(try await harness.store.record(session).title == "keep me")

      let unknown = try await harness.post("/v1/session/no-such-session/title", .object(["title": "x"]))
      #expect(unknown.status == .notFound)
    }
  }
}
