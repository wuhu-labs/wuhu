#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Credentials
import Dependencies
import Fetch
import Scratch
import Testing

@Suite struct CredentialIdentityTests {
  @Test func identitySurvivesReloadAndIdenticalAuthSetRotates() async throws {
    let folder = try ScratchFolder("credential-identity")
    defer { folder.remove() }
    let store = CredentialsStore(configDirectory: folder.url, spaceID: "space")
    try await store.replace(providerID: "openai", credential: .apiKey("fixture-key"))
    let resolver = CredentialResolver.live(store: store, allowEnvironment: false)
    let first = try #require(try await resolver.resolveBinding("openai"))
    let loaded = CredentialResolver.live(store: CredentialsStore(configDirectory: folder.url, spaceID: "space"), allowEnvironment: false)
    #expect(try await loaded.resolveBinding("openai")?.identityEpoch == first.identityEpoch)
    #expect(first.permitsOpaqueReplay)
    #expect(!first.identityEpoch.contains("fixture-key"))
    try await store.replace(providerID: "openai", credential: .apiKey("fixture-key"))
    #expect(try await resolver.resolveBinding("openai")?.identityEpoch != first.identityEpoch)
    let second = try #require(try await resolver.resolveBinding("openai"))
    try await store.update { $0.providers["openai"] = .apiKey("replacement-key") }
    #expect(try await resolver.resolveBinding("openai")?.identityEpoch != second.identityEpoch)
    try await store.replace(providerID: "openai", credential: nil)
    #expect(try await resolver.resolveBinding("openai") == nil)
  }

  @Test func directFileReplacementCannotReuseStoredAffinityMetadata() async throws {
    let folder = try ScratchFolder("credential-file-replacement")
    defer { folder.remove() }
    let store = CredentialsStore(configDirectory: folder.url, spaceID: "space")
    try await store.replace(providerID: "openai", credential: .apiKey("first"))
    let resolver = CredentialResolver.live(store: store, allowEnvironment: false)
    let first = try #require(try await resolver.resolveBinding("openai"))
    var contents = try await store.load()
    contents.providers["openai"] = .apiKey("second")
    try await store.save(contents)
    let replaced = try #require(try await resolver.resolveBinding("openai"))
    #expect(replaced.identityEpoch != first.identityEpoch)
    #expect(replaced.credential == .apiKey("second"))
  }

  @Test func legacyStoreGetsOpaqueMetadataWithoutChangingCredential() async throws {
    let folder = try ScratchFolder("credential-legacy")
    defer { folder.remove() }
    let store = CredentialsStore(configDirectory: folder.url, spaceID: "space")
    try await store.save(.init(providers: ["openai": .apiKey("fixture")]))
    let resolver = CredentialResolver.live(store: store, allowEnvironment: false)
    let binding = try #require(try await resolver.resolveBinding("openai"))
    #expect(binding.credential == .apiKey("fixture"))
    #expect(try await resolver.resolveBinding("openai")?.identityEpoch == binding.identityEpoch)
    #expect(try await store.load().providers["openai"] == .apiKey("fixture"))
  }

  @Test func oauthRefreshPreservesEpochAndReloginRotates() async throws {
    let folder = try ScratchFolder("credential-oauth")
    defer { folder.remove() }
    let store = CredentialsStore(configDirectory: folder.url, spaceID: "space")
    let now = Date(timeIntervalSince1970: 1000)
    let tokens = ChatGPTTokens(idToken: nil, accessToken: "access-one", refreshToken: "refresh-one", accountID: "fixture-account", expiresAt: now.addingTimeInterval(1000))
    try await store.replace(providerID: "codex", credential: .chatGPTOAuth(tokens))
    let resolver = CredentialResolver.live(store: store, allowEnvironment: false)
    let first = try await withDependencies { $0.date = .constant(now) } operation: {
      try #require(try await resolver.resolveBinding("codex"))
    }
    let second = try await withDependencies {
      $0.date = .constant(now.addingTimeInterval(900))
      $0.fetch = FetchClient { _ in
        Response(status: .ok, body: .string(#"{"access_token":"access-two","refresh_token":"refresh-two","expires_in":3600}"#))
      }
    } operation: {
      try #require(try await resolver.resolveBinding("codex"))
    }
    #expect(second.identityEpoch == first.identityEpoch)
    #expect(second.credential == .chatGPT(accessToken: "access-two", accountID: "fixture-account"))
    let refreshed = try await store.load().providers["codex"]
    try await store.replace(providerID: "codex", credential: refreshed)
    let third = try await withDependencies { $0.date = .constant(now.addingTimeInterval(900)) } operation: {
      try #require(try await resolver.resolveBinding("codex"))
    }
    #expect(third.identityEpoch != second.identityEpoch)
  }

  @Test func unverifiedResolverFailsClosedAndTracksReplacement() async throws {
    let state = CredentialState()
    let resolver = CredentialResolver { _ in await state.value }
    let first = try #require(try await resolver.resolveBinding("provider"))
    #expect(!first.permitsOpaqueReplay)
    #expect(try await resolver.resolveBinding("provider")?.identityEpoch == first.identityEpoch)
    await state.replace()
    #expect(try await resolver.resolveBinding("provider")?.identityEpoch != first.identityEpoch)
  }
}

private actor CredentialState {
  var value: ProviderCredential = .apiKey("one")
  func replace() { value = .apiKey("two") }
}
