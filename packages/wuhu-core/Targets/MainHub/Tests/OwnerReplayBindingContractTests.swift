import Credentials
import Dependencies
import DeterministicDependencies
import ExecutionOwner
import Fetch
import MainHub
import protocol MainHub.Main
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

  @Test func portableHandoffUsesConditionalSessionOwnerCommit() async throws {
    let space = try Space.inMemory()
    let id = try await space.sessions.createSession(group: .shared, title: "owner handoff", kind: .agent, createdBy: "fixture", model: .init(provider: "fixture", model: "model", effort: "high"))
    let owner: any Main = Hub(space: space)
    let hydration = try await owner.hydrate(id)
    guard case let .kernel(source) = hydration.transcript else { Issue.record("expected kernel transcript"); return }
    let binding = ReplayBinding(identity: "owner-binding", epoch: "owner-route")
    let projected = try withDependencies {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      try source.portableHandoff(binding: binding, budget: .init(maxInput: 10000, maxOutput: 1000), runningWork: [])
    }
    let committed = try await owner.append(id, .portableHandoff(expectedGeneration: hydration.generation, source: source, transcript: projected, transition: nil)).value(Transcript.self)
    #expect(committed == projected)
    #expect(try await owner.hydrate(id).generation == hydration.generation + 1)
    #expect(try await owner.hydrate(id).transcript == .kernel(projected))
  }
}
