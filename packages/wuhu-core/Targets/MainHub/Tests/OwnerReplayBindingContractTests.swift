import Credentials
import Dependencies
import DeterministicDependencies
import ExecutionOwner
import Fetch
import MainHub
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
import SessionDomain
import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct OwnerReplayBindingContractTests {
  @Test func liveCredentialEpochSurvivesOwnerRefreshAndRotatesOnReplacement() async throws {
    let folder = try ScratchFolder("owner-replay-credentials")
    defer { folder.remove() }
    let store = CredentialsStore(configDirectory: folder.url, spaceID: "owner-space")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let tokens = ChatGPTTokens(idToken: nil, accessToken: "access-one", refreshToken: "refresh-one", accountID: "fixture-account", expiresAt: now.addingTimeInterval(1000))
    try await store.replace(providerID: "codex", credential: .chatGPTOAuth(tokens))
    let resolver = CredentialResolver.live(store: store, allowEnvironment: false)
    let first = try await withDependencies { $0.date = .constant(now) } operation: {
      try #require(try await resolver.resolveBinding("codex"))
    }
    #expect(first.permitsOpaqueReplay)
    #expect(first.credential == .chatGPT(accessToken: "access-one", accountID: "fixture-account"))
    let refreshed = try await withDependencies {
      $0.date = .constant(now.addingTimeInterval(900))
      $0.fetch = FetchClient { _ in Response(status: .ok, body: .string(#"{"access_token":"access-two","refresh_token":"refresh-two","expires_in":3600}"#)) }
    } operation: {
      try #require(try await resolver.resolveBinding("codex"))
    }
    #expect(refreshed.identityEpoch == first.identityEpoch)
    #expect(refreshed.permitsOpaqueReplay)
    #expect(refreshed.credential == .chatGPT(accessToken: "access-two", accountID: "fixture-account"))
    try await store.replace(providerID: "codex", credential: .chatGPTOAuth(tokens))
    let replacement = try await withDependencies { $0.date = .constant(now) } operation: {
      try #require(try await resolver.resolveBinding("codex"))
    }
    #expect(replacement.identityEpoch != first.identityEpoch)
    #expect(try await resolver.resolveBinding("missing") == nil)
  }
}
