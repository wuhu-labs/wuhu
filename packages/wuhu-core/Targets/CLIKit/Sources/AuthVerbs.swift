#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum Credentials.ChatGPTAuth
import struct Credentials.ChatGPTTokens
import struct Credentials.CredentialsStore
import enum Credentials.StoredCredential
import Dependencies
import struct InferenceKit.ModelsDocument
import JSONValue
import struct SpaceContract.ReadOutput

extension Executor {
  func credentialsStore() throws -> CredentialsStore {
    let space = try wallet.pinnedSpace()
    let endpoint = try endpoint(space: space)
    guard let identity = try SpaceIdentityStore(environment: runner.environment).identity(forHost: endpoint.key) else {
      throw CLIError(message: """
      no space identity recorded for \(endpoint.key)
      enroll first (wuhu login < invite-link) so credentials bind to the space id
      """)
    }
    return CredentialsStore(
      configDirectory: try ServerTrust.userConfigDirectory(environment: runner.environment),
      spaceID: identity,
    )
  }

  mutating func authSet(provider: String) async throws {
    let store = try credentialsStore()
    let key = (try await runner.stdin()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw UsageError(message: "auth set: pass the API key on stdin")
    }
    try await store.update { $0.providers[provider] = .apiKey(key) }
    await runner.stdout("stored api key for \(provider) in \(store.file.path)\n")
  }

  func authList() async throws {
    let store = try credentialsStore()
    let contents = try await store.load()
    guard !contents.providers.isEmpty else {
      await runner.stdout("no credentials stored (\(store.file.path))\n")
      return
    }
    @Dependency(\.date.now) var now
    var text = ""
    for (provider, credential) in contents.providers.sorted(by: { $0.key < $1.key }) {
      switch credential {
      case .apiKey:
        text += "\(provider): api key\n"
      case .claudeCodeOAuth:
        text += "\(provider): claude code setup token\n"
      case let .chatGPTOAuth(tokens):
        let remaining = tokens.expiresAt.timeIntervalSince(now)
        let state = remaining > 0
          ? "access token valid \(Int(remaining / 60))m, auto-refreshes"
          : "access token expired, refreshes on next use"
        text += "\(provider): chatgpt account \(tokens.accountID), \(state)\n"
      }
    }
    await runner.stdout(text)
  }

  mutating func authRemove(provider: String) async throws {
    let store = try credentialsStore()
    guard try await store.load().providers[provider] != nil else {
      throw CLIError(message: "no credentials stored for \(provider)")
    }
    try await store.update { $0.providers[provider] = nil }
    await runner.stdout("removed credentials for \(provider)\n")
  }

  mutating func authLogin(provider: String) async throws {
    let space = try wallet.pinnedSpace()
    let output: ReadOutput = try await authenticated(space).tool(
      "read", ["path": .string(ModelsDocument.spacePath)],
    )
    let document = try ModelsDocument(json: Data(output.content.utf8))
    guard let definition = document.providers[provider] else {
      throw CLIError(message: "unknown provider \(provider) in \(ModelsDocument.spacePath)")
    }
    let store = try credentialsStore()
    switch definition.dialect {
    case .codex:
      let authorization = try await ChatGPTAuth.startDeviceAuthorization()
      await runner.stdout("""
      open \(ChatGPTAuth.deviceVerificationURL.absoluteString)
      enter code: \(authorization.userCode)
      waiting for approval (times out after 15 minutes)...
      """ + "\n")
      let tokens = try await ChatGPTAuth.awaitDeviceGrant(authorization)
      try await store.update { $0.providers[provider] = .chatGPTOAuth(tokens) }
      await runner.stdout("logged in: chatgpt account \(tokens.accountID), stored for \(provider) in \(store.file.path)\n")
    case .claude, .anthropic, .responses:
      throw CLIError(message: "provider \(provider) uses API keys; run `wuhu auth set \(provider)`")
    }
  }

  mutating func authLogout(provider: String) async throws {
    let store = try credentialsStore()
    switch try await store.load().providers[provider] {
    case let .chatGPTOAuth(tokens):
      do {
        try await ChatGPTAuth.revoke(tokens)
      } catch {
        await runner.stdout("warning: token revocation failed (\(error)); removing local credentials anyway\n")
      }
    case .claudeCodeOAuth:
      break
    case .apiKey, nil:
      throw CLIError(message: "no login stored for \(provider) (api keys are removed with `wuhu auth remove`)")
    }
    try await store.update { $0.providers[provider] = nil }
    await runner.stdout("logged out \(provider)\n")
  }
}
