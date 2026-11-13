import Crypto
import Fetch
import Foundation
import JSONValue
import Scratch
import Serve
import ServeTesting
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.serialized)
struct EvictionAnswerTests {
  /// Two processes on one database, as a release roll leaves them: the first
  /// holds the identity cell, so the second's call to it is refused, and the
  /// route answers that refusal rather than a 500.
  @Test func aCallRefusedWithEvictedAnswersServiceUnavailable() async throws {
    try await withSessionDeps {
      let folder = try ScratchFolder("eviction-answer")
      let file = folder.url.appending(path: "space.sqlite")
      let key = try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation)
      let holder = IdentityController.configure(
        space: try Space.open(file: file),
        origin: "https://space.test",
        keys: MemoryFiles().identityKeys,
        fetch: FetchClient { _ in Response(status: .forbidden) },
      )
      try await holder.initialize(identity: key)

      let space = try Space.open(file: file)
      let controller = IdentityController.configure(
        space: space,
        origin: "https://space.test",
        keys: MemoryFiles().identityKeys,
        fetch: FetchClient { _ in Response(status: .forbidden) },
      )
      do {
        let harness = try await Harness(identityController: controller, opening: { space })
        var request = Request(url: try #require(URL(string: "https://space.test/v1/identity")), method: .put)
        request.body = try .json(["defaultIssuer": "self"])
        let response = try await harness.api(request)
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.retryAfter] == "1")
        #expect(try await json(response).object?["code"] == .string(ErrorCode.unavailable.rawValue))
      } catch {
        try? await space.close()
        try? await holder.space.close()
        throw error
      }

      try await space.close()
      try await holder.space.close()
    }
  }
}
