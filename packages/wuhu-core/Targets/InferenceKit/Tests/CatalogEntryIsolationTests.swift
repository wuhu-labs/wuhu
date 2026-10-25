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

extension CatalogEntryIsolationTests {
  @Test func invalidCapacityAndGroupStayLocalAtUseTime() async throws {
    var source = try ModelsDocument(json: fixtureJSON)
    source.providers["openai"]!.capacity = ["weekly": 2]
    let groups = Data(#"{"mixed":{"kind":"group","members":[{"id":"a","provider":"anthropic","model":"claude-sonnet-5"},{"id":"b","provider":"openai","model":"gpt-5.4"}],"defaultEffort":"high"},"good":{"kind":"group","members":[{"id":"a","provider":"anthropic","model":"claude-sonnet-5"}],"defaultEffort":"high"},"bad":{"kind":"group","members":[{"id":"b","provider":"openai","model":"gpt-5.4"}],"defaultEffort":"high"}}"#.utf8)
    let document = try ModelsDocument(json: JSONEncoder().encode(source), groupsJSON: groups)
    let catalog = ProviderCatalog(document: document, credentials: .init { _ in .apiKey("fixture") })
    let error = CatalogError.invalidCapacity(provider: "openai", window: "weekly")
    #expect(throws: error) { try catalog.validate(.init(provider: "openai", model: "gpt-5.4", effort: "high")) }
    #expect(throws: CatalogError.groupMember(group: "bad", member: "b", reason: error)) { try catalog.validateGroup("bad") }
    #expect(try catalog.validateGroup("good") == "high")
    let resolved = try await catalog.resolve(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "high"), session: .init("test"))
    #expect(resolved.specifier.provider == "anthropic")
    #expect(catalog.providerErrors == ["openai": error])
    #expect(catalog.groupErrors.keys.sorted() == ["bad"])
    let validated = try catalog.validatedGroup("mixed")
    #expect(validated.memberErrors["b"] == .groupMember(group: "mixed", member: "b", reason: error))
    #expect(try await catalog.validateGroupReadiness("mixed") == "high")
    let placement = try placeModelGroup(id: "mixed", group: document.groups["mixed"]!, providers: document.providers, usage: [:], now: Date(), reason: .create)
    #expect(placement.member.id == "a")
    #expect(placement.evidence.map(\.member) == ["a"])
  }

  @Test(arguments: [#"{"kind":"group","members":[],"defaultEffort":"high","policy":{"type":"unknown"}}"#, #"{"kind":"group","members":"wrong"}"#, "null"])
  func malformedGroupDoesNotPoisonHealthyGroup(_ bad: String) throws {
    let groups = Data((#"{"good":{"kind":"group","members":[{"id":"a","provider":"anthropic","model":"claude-sonnet-5"}],"defaultEffort":"high"},"bad":"# + bad + "}").utf8)
    let document = try ModelsDocument(json: fixtureJSON, groupsJSON: groups)
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    #expect(try catalog.validateGroup("good") == "high")
    #expect(throws: CatalogError.self) { try catalog.validateGroup("bad") }
    #expect(catalog.groupErrors.keys.sorted() == ["bad"])
  }

  @Test(arguments: [#"{"dialect":"unknown"}"#, "null", #"{"capacity":"wrong"}"#])
  func malformedProviderDoesNotPoisonHealthyProvider(_ bad: String) throws {
    let text = String(decoding: fixtureJSON, as: UTF8.self)
    let json = Data(("{\"bad\":" + bad + "," + text.dropFirst()).utf8)
    let catalog = ProviderCatalog(document: try ModelsDocument(json: json), credentials: .unavailable)
    _ = try catalog.validate(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "high"))
    #expect(throws: CatalogError.self) { try catalog.validate(.init(provider: "bad", model: "m", effort: "high")) }
    #expect(catalog.providerErrors.keys.sorted() == ["bad"])
    #expect(throws: CatalogError.self) { try JSONEncoder().encode(catalog.document) }
  }

  @Test func malformedSelectedCapabilityCredentialDoesNotFallBack() async throws {
    let config = Data(#"{"image":{"active":"test","providers":{"test":{"dialect":"codex","credential":"broken"}}}}"#.utf8)
    let client = try await CapabilityClient.load(read: { path in
      if path == "/capabilities.json" { return config }
      if path == ModelsDocument.spacePath { return Data(#"{"broken":{"dialect":"unknown"}}"#.utf8) }
      return nil
    }, credentials: mixedCatalogCredentials)
    #expect(throws: CapabilityError.self) { try client.capability("image") }
  }

  @Test(arguments: ["[]", "null", "1", "{invalid"])
  func unreadableFilesStillFail(_ json: String) {
    #expect(throws: CatalogError.invalidDocument) { try ModelsDocument(json: Data(json.utf8)) }
    #expect(throws: CatalogError.invalidGroupsDocument) { try ModelsDocument(json: fixtureJSON, groupsJSON: Data(json.utf8)) }
  }
}
