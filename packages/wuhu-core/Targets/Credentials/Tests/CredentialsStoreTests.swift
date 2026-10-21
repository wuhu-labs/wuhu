#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import Credentials
import Dependencies
import Scratch
import Testing

@Suite struct CredentialsStoreTests {
  @Test func loadAbsentFileIsEmpty() async throws {
    let scratch = try ScratchFolder("credentials-tests")
    defer { scratch.remove() }
    let store = CredentialsStore(configDirectory: scratch.url, spaceID: "spc_test")
    #expect(try await store.load() == .empty)
  }

  @Test func roundTripsAllCredentialKinds() async throws {
    let scratch = try ScratchFolder("credentials-tests")
    defer { scratch.remove() }
    let directory = scratch.url
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CredentialsStore(configDirectory: directory, spaceID: "spc_test")
    let tokens = ChatGPTTokens(
      idToken: "id.jwt.value",
      accessToken: "access.jwt.value",
      refreshToken: "refresh-value",
      accountID: "acct-123",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
    )
    let contents = CredentialsFile(providers: [
      "anthropic": .apiKey("sk-ant-test"),
      "codex": .chatGPTOAuth(tokens),
    ])
    try await store.save(contents)
    #expect(try await store.load() == contents)
  }

  @Test func savesWithOwnerOnlyPermissions() async throws {
    let scratch = try ScratchFolder("credentials-tests")
    defer { scratch.remove() }
    let directory = scratch.url
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CredentialsStore(configDirectory: directory, spaceID: "spc_test")
    try await store.save(CredentialsFile(providers: ["openai": .apiKey("sk-test")]))
    let fileMode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
    let directoryMode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
    #expect(fileMode == 0o600)
    #expect(directoryMode == 0o700)
  }

  @Test func updateMutatesInPlace() async throws {
    let scratch = try ScratchFolder("credentials-tests")
    defer { scratch.remove() }
    let directory = scratch.url
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CredentialsStore(configDirectory: directory, spaceID: "spc_test")
    try await store.save(CredentialsFile(providers: ["openai": .apiKey("old")]))
    try await store.update { $0.providers["openai"] = .apiKey("new") }
    #expect(try await store.load().providers["openai"] == .apiKey("new"))
  }

  @Test func malformedStoreFailsLoudly() async throws {
    let scratch = try ScratchFolder("credentials-tests")
    defer { scratch.remove() }
    let directory = scratch.url
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CredentialsStore(configDirectory: directory, spaceID: "spc_test")
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: store.file)
    await #expect(throws: CredentialsStoreError.self) {
      try await store.load()
    }
  }
}

@Suite struct ChatGPTTokenLogicTests {
  @Test func refreshWindowIsFiveMinutes() {
    let tokens = ChatGPTTokens(
      idToken: nil,
      accessToken: "a",
      refreshToken: "r",
      accountID: "acct",
      expiresAt: Date(timeIntervalSince1970: 10000),
    )
    #expect(!tokens.needsRefresh(at: Date(timeIntervalSince1970: 9699)))
    #expect(tokens.needsRefresh(at: Date(timeIntervalSince1970: 9701)))
  }

  @Test func extractsAccountIDFromJWT() throws {
    let claims = #"{"exp": 1800000000, "https://api.openai.com/auth": {"chatgpt_account_id": "acct-42"}}"#
    let payload = Data(claims.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let jwt = "header.\(payload).signature"
    #expect(ChatGPTAuth.accountID(fromAccessToken: jwt) == "acct-42")
    #expect(ChatGPTAuth.jwtClaims(jwt)?.exp == 1_800_000_000)
  }

  @Test func mergesRefreshResponseOverPrevious() throws {
    let previous = ChatGPTTokens(
      idToken: "old-id",
      accessToken: "old-access",
      refreshToken: "old-refresh",
      accountID: "acct-42",
      expiresAt: Date(timeIntervalSince1970: 0),
    )
    let response = TokenResponse(idToken: nil, accessToken: nil, refreshToken: "rotated", expiresIn: nil)
    let merged = try withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    } operation: {
      try ChatGPTAuth.tokens(from: response, previous: previous)
    }
    #expect(merged.idToken == "old-id")
    #expect(merged.accessToken == "old-access")
    #expect(merged.refreshToken == "rotated")
    #expect(merged.accountID == "acct-42")
    #expect(merged.expiresAt == Date(timeIntervalSince1970: 4600))
  }

  @Test func permanentRefreshFailuresAreClassified() {
    #expect(ChatGPTAuth.isPermanentRefreshFailure(status: .unauthorized, body: ""))
    #expect(ChatGPTAuth.isPermanentRefreshFailure(status: .badRequest, body: #"{"error": "refresh_token_reused"}"#))
    #expect(!ChatGPTAuth.isPermanentRefreshFailure(status: .badRequest, body: #"{"error": "server_error"}"#))
    #expect(!ChatGPTAuth.isPermanentRefreshFailure(status: .serviceUnavailable, body: ""))
  }

  @Test func deviceGrantStatesAreClassified() {
    #expect(ChatGPTAuth.deviceGrantState(status: .forbidden, body: "") == .pending)
    #expect(ChatGPTAuth.deviceGrantState(status: .notFound, body: "") == .pending)
    #expect(ChatGPTAuth.deviceGrantState(status: .badRequest, body: #"{"error": "deviceauth_authorization_pending"}"#) == .pending)
    #expect(ChatGPTAuth.deviceGrantState(status: .tooManyRequests, body: #"{"error": "slow_down"}"#) == .slowDown)
    #expect(ChatGPTAuth.deviceGrantState(status: .badRequest, body: #"{"error": "expired"}"#) == .failed)
  }
}

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@Suite(.serialized) struct CredentialEnvironmentPolicyTests {
  @Test func disabledEnvironmentUsesOnlyItsOwnStore() async throws {
    let previous = ProcessInfo.processInfo.environment["TEST_PROVIDER_API_KEY"]
    setenv("TEST_PROVIDER_API_KEY", "process-key", 1)
    defer {
      if let previous { setenv("TEST_PROVIDER_API_KEY", previous, 1) }
      else { unsetenv("TEST_PROVIDER_API_KEY") }
    }
    let folder = try scratchURL("credential-policy")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CredentialsStore(configDirectory: folder, spaceID: "spc_policy")
    let resolver = CredentialResolver.live(store: store, allowEnvironment: false)
    try await store.save(CredentialsFile(providers: ["test-provider": .apiKey("space-one")]))
    #expect(try await resolver.resolve("test-provider") == .apiKey("space-one"))
    #expect(try await CredentialResolver.live(store: store, allowEnvironment: true).resolve("test-provider") == .apiKey("process-key"))
    let other = CredentialResolver.live(store: CredentialsStore(configDirectory: folder, spaceID: "spc_other"), allowEnvironment: false)
    #expect(try await other.resolve("test-provider") == nil)
    #expect(try await resolver.resolve("missing-provider") == nil)
  }
}

extension CredentialEnvironmentPolicyTests {
  @Test func environmentIdentityPersistsAndReplacementRotates() async throws {
    let name = "REPLAY_TEST_API_KEY"
    let previous = ProcessInfo.processInfo.environment[name]
    defer {
      if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
    }
    let folder = try ScratchFolder("environment-replay")
    defer { folder.remove() }
    let store = CredentialsStore(configDirectory: folder.url, spaceID: "space")
    let resolver = CredentialResolver.live(store: store)
    setenv(name, "fixture-one", 1)
    let first = try #require(try await resolver.resolveBinding("replay-test"))
    #expect(first.permitsOpaqueReplay)
    #expect(try await CredentialResolver.live(store: store).resolveBinding("replay-test")?.identityEpoch == first.identityEpoch)
    setenv(name, "fixture-two", 1)
    let second = try #require(try await resolver.resolveBinding("replay-test"))
    #expect(second.identityEpoch != first.identityEpoch)
    setenv(name, "fixture-one", 1)
    #expect(try await resolver.resolveBinding("replay-test")?.identityEpoch != first.identityEpoch)
    unsetenv(name)
    #expect(try await resolver.resolveBinding("replay-test") == nil)
    setenv(name, "fixture-one", 1)
    #expect(try await resolver.resolveBinding("replay-test")?.identityEpoch != first.identityEpoch)
  }
}

extension CredentialEnvironmentPolicyTests {
  @Test func environmentOnlyVerifiesKeyAndRetiresTransientIdentityOnRemoval() async throws {
    let name = "ENV_ONLY_REPLAY_TEST_API_KEY"
    let previous = ProcessInfo.processInfo.environment[name]
    defer {
      if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
    }
    let resolver = CredentialResolver.environmentOnly
    setenv(name, "fixture-one", 1)
    let first = try #require(try await resolver.resolveBinding("env-only-replay-test"))
    #expect(first.permitsOpaqueReplay)
    #expect(first.credential == .apiKey("fixture-one"))
    #expect(try await resolver.resolveBinding("env-only-replay-test")?.identityEpoch == first.identityEpoch)
    #expect(!first.identityEpoch.contains("fixture-one"))
    setenv(name, "fixture-two", 1)
    let replacement = try #require(try await resolver.resolveBinding("env-only-replay-test"))
    #expect(replacement.identityEpoch != first.identityEpoch)
    setenv(name, "fixture-one", 1)
    let restored = try #require(try await resolver.resolveBinding("env-only-replay-test"))
    #expect(restored.identityEpoch != first.identityEpoch)
    unsetenv(name)
    #expect(try await resolver.resolveBinding("env-only-replay-test") == nil)
    setenv(name, "fixture-one", 1)
    #expect(try await resolver.resolveBinding("env-only-replay-test")?.identityEpoch != restored.identityEpoch)
  }
}
