import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing

@Suite struct SessionTagsRouteTests {
  @Test func aHumanReplacesTheWholeTagListEvenOnAnArchivedSession() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession(title: "coder")

      struct Tagged: Decodable { let tags: [String] }
      let tagged = try await harness.call(
        "/v1/session/\(session.rawValue)/tags", .object(["tags": ["wuhu:13", "gate"]]), as: Tagged.self,
      )
      #expect(tagged.tags == ["wuhu:13", "gate"])
      #expect(try await harness.store.record(session).tags == ["wuhu:13", "gate"])

      _ = try await harness.store.archive(session, grace: .seconds(3600))
      _ = try await harness.call("/v1/session/\(session.rawValue)/tags", .object(["tags": []]), as: Tagged.self)
      #expect(try await harness.store.record(session).tags == [])

      let malformed = try await harness.post("/v1/session/\(session.rawValue)/tags", .object(["tags": "one"]))
      #expect(malformed.status == .badRequest)
      let unknown = try await harness.post("/v1/session/no-such-session/tags", .object(["tags": []]))
      #expect(unknown.status == .notFound)
    }
  }

  @Test func creationRefusesAnUnusableTitle() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let refused = try await harness.post(
        "/v1/session",
        .object(["kind": "agent", "title": "two\nlines", "provider": "testing", "model": "test-model"]),
      )
      #expect(refused.status == .unprocessableContent)
      #expect(try await refused.text().contains("unusable title"))
    }
  }
}
