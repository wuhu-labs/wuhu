import Credentials
import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import JSONValue
import SessionDomain
import Testing
import WuhuAI

private func mixedReplayCatalogJSON(policy: JSONValue? = nil) -> Data {
  let policyField = policy.map { ",\"opaqueReplay\":\($0.jsonString(sortedKeys: true))" } ?? ""
  return Data("""
  {
    "unsticky": {"dialect":"anthropic", "baseURL":"https://unsticky.test"\(policyField),
      "models": {
        "thinking":{"maxInput":10000,"maxOutput":1000,"efforts":["none","high"],"defaultEffort":"high"},
        "plain":{"maxInput":10000,"maxOutput":1000,"efforts":["none"],"defaultEffort":"none"}
      }},
    "work-codex": {"dialect":"codex", "baseURL":"https://configured-codex.test/backend-api/codex",
      "originator":"configured-originator",
      "models":{"codex-model":{"maxInput":10000,"maxOutput":1000,"efforts":["high"],"defaultEffort":"high"}}}
  }
  """.utf8)
}

private let mixedCatalogCredentials = CredentialResolver.bound { provider in
  let credential: ProviderCredential = provider == "work-codex"
    ? .chatGPT(accessToken: "fixture-token", accountID: "fixture-account") : .apiKey("fixture-key")
  return CredentialBinding(credential: credential, identityEpoch: "fixture-epoch")
}

@Suite(.deterministicDependencies) struct CatalogEntryIsolationTests {
  @Test(arguments: [JSONValue?.none, .some(.string("none"))])
  func mixedCatalogRetainsValidEntriesAndAcceptsThinkingWithoutReplay(policy: JSONValue?) async throws {
    let document = try ModelsDocument(json: mixedReplayCatalogJSON(policy: policy))
    #expect(document.providers.count == 2)
    #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
    let catalog = ProviderCatalog(document: document, credentials: mixedCatalogCredentials)
    let valid = try await catalog.resolve(.init(provider: "work-codex", model: "codex-model", effort: "high"), session: .init("test"))
    #expect(valid.specifier.provider == "work-codex")
    try catalog.validate(.init(provider: "unsticky", model: "plain", effort: "none"))
    try catalog.validate(.init(provider: "unsticky", model: "thinking", effort: "none"))
    try catalog.validate(.init(provider: "unsticky", model: "thinking", effort: "high"))
    let thinking = try await catalog.resolve(.init(provider: "unsticky", model: "thinking", effort: "high"), session: .init("test"))
    #expect(thinking.specifier.effort == "high")
    #expect(thinking.replayScope == nil)
  }

  @Test(arguments: [JSONValue.string("unknown"), .integer(7), .array([.string("affine")]), .object(["mode": .string("affine")])])
  func unknownReplayPolicyIsRetainedButCannotBeSelected(policy: JSONValue) async throws {
    let document = try ModelsDocument(json: mixedReplayCatalogJSON(policy: policy))
    #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
    let catalog = ProviderCatalog(document: document, credentials: mixedCatalogCredentials)
    let value = if case let .string(value) = policy { value } else { "non-string" }
    let error = CatalogError.invalidOpaqueReplay(provider: "unsticky", value: value)
    #expect(throws: error) { try catalog.validate(.init(provider: "unsticky", model: "plain", effort: "none")) }
    await #expect(throws: InferenceError.invalidInput(status: 422, body: error.description)) {
      try await catalog.resolve(.init(provider: "unsticky", model: "thinking", effort: "high"), session: .init("test"))
    }
    _ = try await catalog.resolve(.init(provider: "work-codex", model: "codex-model", effort: "high"), session: .init("test"))
  }

  @Test(arguments: [JSONValue?.none, .some(.string("none")), .some(.string("unknown")), .some(.integer(7))])
  func mixedCatalogKeepsConfiguredCodexCapabilityAliasEndpointAndOriginator(policy: JSONValue?) async throws {
    let provider = try await CapabilityClient.load(read: { path in
      path == ModelsDocument.spacePath ? mixedReplayCatalogJSON(policy: policy) : nil
    }, credentials: mixedCatalogCredentials)
    #expect(try provider.capability("image")["provider"] == .string("codex"))
    let fetch = FetchClient { request in
      #expect(request.url.absoluteString == "https://configured-codex.test/backend-api/codex/images/generations")
      #expect(request.headers["originator"] == "configured-originator")
      #expect(request.headers.sensitiveValues["authorization"] == "Bearer fixture-token")
      return Response(status: .ok, body: .string(#"{"data":[{"b64_json":"UE5H"}]}"#))
    }
    let image = try await withDependencies { $0.fetch = fetch } operation: { try await provider.image("moon") }
    #expect(image == Data("PNG".utf8))
  }
}
