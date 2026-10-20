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
    let owner: any Main = Hub(space: try Space.inMemory(), credentials: .live(store: store, allowEnvironment: false))
    let first = try await withDependencies { $0.date = .constant(now) } operation: {
      try #require(try await owner.providerCredentialBinding("codex"))
    }
    #expect(first.permitsOpaqueReplay)
    #expect(first.credential == .chatGPT(accessToken: "access-one", accountID: "fixture-account"))
    let refreshed = try await withDependencies {
      $0.date = .constant(now.addingTimeInterval(900))
      $0.fetch = FetchClient { _ in Response(status: .ok, body: .string(#"{"access_token":"access-two","refresh_token":"refresh-two","expires_in":3600}"#)) }
    } operation: {
      try #require(try await owner.providerCredentialBinding("codex"))
    }
    #expect(refreshed.identityEpoch == first.identityEpoch)
    #expect(refreshed.permitsOpaqueReplay)
    #expect(refreshed.credential == .chatGPT(accessToken: "access-two", accountID: "fixture-account"))
    try await store.replace(providerID: "codex", credential: .chatGPTOAuth(tokens))
    let replacement = try await withDependencies { $0.date = .constant(now) } operation: {
      try #require(try await owner.providerCredentialBinding("codex"))
    }
    #expect(replacement.identityEpoch != first.identityEpoch)
    #expect(try await owner.providerCredentialBinding("missing") == nil)
  }

  @Test func oidcIdentityIsAnOptionalSemanticOwnerEffect() async throws {
    let audience = URL(string: "https://provider.example")!
    let session = SessionID("owner-session")
    let owner: any Main = Hub(
      space: try Space.inMemory(), inferenceToken: { requested, caller in
        #expect(requested == audience && caller == session)
        return "fixture-bearer"
      }, inferenceBindingIdentity: { requested, caller in
        #expect(requested == audience && caller == session)
        return "fixture-stable-identity"
      },
    )
    #expect(try await owner.inferenceToken(audience: audience, session: session) == "fixture-bearer")
    #expect(try await owner.inferenceBindingIdentity(audience: audience, session: session) == "fixture-stable-identity")
    let unavailable: any Main = Hub(space: try Space.inMemory())
    #expect(try await unavailable.inferenceBindingIdentity(audience: audience, session: session) == nil)
    #expect(try await unavailable.providerCredentialBinding("missing") == nil)
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
