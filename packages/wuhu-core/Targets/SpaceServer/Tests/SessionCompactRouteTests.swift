import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SessionCompactRouteTests {
  @Test func kernelSessionsTakeTheVerbToo() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let accepted = try await harness.post(
        "/v1/session/\(id.rawValue)/compact", .object(["instructions": .string("keep the build notes")]),
      )
      #expect(accepted.status == .ok)
      try await until("compact requested") {
        try await harness.store.transcript(id).items.contains {
          if case let .notification(notification) = $0 { notification.kind == .compactRequest && notification.content.text == "keep the build notes" } else { false }
        }
      }

      #expect(try await harness.post("/v1/session/nope/compact", .null).status == .notFound)
    }
  }
}
