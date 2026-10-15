import Credentials
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import SessionDomain
import Testing
import WuhuAI

@Suite struct ReplayBindingTests {
  private let specifier = ModelSpecifier(provider: "openai", model: "gpt-5.4", effort: "high")
  private let session = SessionID("replay-test")

  private func resolve(_ document: ModelsDocument, epoch: String = "credential-epoch", token: String = "fixture-token", routeEpoch: String = "route-one", provider: String = "openai") async throws -> ResolvedModel {
    let credentials = CredentialResolver.bound({ _ in
      CredentialBinding(credential: .apiKey(token), identityEpoch: epoch)
    })
    return try await ProviderCatalog(document: document, credentials: credentials).resolve(
      .init(provider: provider, model: "gpt-5.4", effort: "high"), session: session, routeEpoch: routeEpoch,
    )
  }

  @Test func scopesBindProviderCredentialAndWireConfigurationNotBearerOrRoute() async throws {
    let document = try ModelsDocument(json: fixtureJSON)
    let first = try await resolve(document)
    #expect(first.replayScope == first.bindingIdentity)
    #expect(first.endpoint.replayScope == first.replayScope)
    #expect(first.endpoint.routeEpoch == "route-one")
    let refresh = try await resolve(document, token: "new-access-token")
    #expect(refresh.replayScope == first.replayScope)
    #expect(refresh.socketIdentity != first.socketIdentity)
    let relogin = try await resolve(document, epoch: "new-credential-epoch")
    #expect(relogin.replayScope != first.replayScope)
    let newRoute = try await resolve(document, routeEpoch: "route-two")
    #expect(newRoute.replayScope == first.replayScope)
    #expect(newRoute.socketIdentity != first.socketIdentity)
    #expect((newRoute.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey != (first.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey)
    var alias = document
    alias.providers["alias"] = document.providers["openai"]
    #expect(try await resolve(alias, provider: "alias").replayScope != first.replayScope)
    var changed = document
    changed.providers["openai"]?.baseURL = URL(string: "https://proxy.test/v1")!
    changed.providers["openai"]?.opaqueReplay = .affine
    #expect(try await resolve(changed).replayScope != first.replayScope)
    changed = document
    changed.providers["openai"]?.transport = .websocket
    #expect(try await resolve(changed).replayScope != first.replayScope)
    changed = document
    changed.providers["openai"]?.originator = "different-wire-originator"
    #expect(try await resolve(changed).replayScope != first.replayScope)
    changed = document
    changed.providers["openai"]?.models["gpt-5.4"]?.maxInput = 900_000
    #expect(try await resolve(changed).replayScope == first.replayScope)
    #expect(first.bindingIdentity.count == 64)
    #expect(!first.bindingIdentity.contains("fixture-token"))
    #expect(!first.bindingIdentity.contains("credential-epoch"))
  }

  @Test func noReplayStillHasReplacementAndRouteScopedBinding() async throws {
    var document = try ModelsDocument(json: fixtureJSON)
    document.providers["openai"]?.opaqueReplay = ModelsDocument.OpaqueReplay.none
    let first = try await resolve(document)
    #expect(first.replayScope == nil)
    #expect(first.endpoint.replayScope == nil)
    var affine = document
    affine.providers["openai"]?.opaqueReplay = .affine
    #expect(try await resolve(affine).bindingIdentity != first.bindingIdentity)
    let replacement = try await resolve(document, epoch: "replacement")
    #expect(replacement.bindingIdentity != first.bindingIdentity)
    #expect(replacement.socketIdentity != first.socketIdentity)
    #expect((replacement.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey != (first.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey)
    let route = try await resolve(document, routeEpoch: "route-two")
    #expect(route.bindingIdentity == first.bindingIdentity)
    #expect((route.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey != (first.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey)
  }

  @Test func firstPartyDefaultsRequireDialectAndExactHTTPSOrigin() throws {
    let models: [String: ModelsDocument.Model] = [:]
    for (dialect, host) in [(ModelsDocument.Dialect.anthropic, "api.anthropic.com"), (.claude, "api.anthropic.com"), (.responses, "api.openai.com"), (.codex, "chatgpt.com")] {
      let provider = ModelsDocument.Provider(dialect: dialect, baseURL: URL(string: "https://\(host)/v1")!, models: models)
      #expect(provider.effectiveOpaqueReplay == .affine)
      for url in ["http://\(host)", "https://\(host).proxy.test", "https://\(host):444", "https://user@\(host)", "https://proxy.test"] {
        var changed = provider
        changed.baseURL = URL(string: url)!
        #expect(changed.effectiveOpaqueReplay == .none)
      }
    }
    let wrongDialect = ModelsDocument.Provider(dialect: .anthropic, baseURL: URL(string: "https://api.openai.com")!, models: models)
    #expect(wrongDialect.effectiveOpaqueReplay == .none)
  }

  @Test func unknownPolicyIsTypedAtSelectionAndRoundTripsWithoutPoisoningRead() throws {
    let json = String(decoding: fixtureJSON, as: UTF8.self)
      .replacingOccurrences(of: "\"dialect\": \"responses\",", with: "\"dialect\": \"responses\", \"opaqueReplay\": \"unsafe\",")
    let invalid = try ModelsDocument(json: Data(json.utf8))
    #expect(try ModelsDocument(json: JSONEncoder().encode(invalid)) == invalid)
    #expect(throws: CatalogError.invalidOpaqueReplay(provider: "openai", value: "unsafe")) {
      try ProviderCatalog(document: invalid, credentials: .unavailable).validate(.init(provider: "openai", model: "gpt-5.4", effort: "high"))
    }
    var corrected = invalid
    corrected.providers["openai"]?.opaqueReplay = ModelsDocument.OpaqueReplay.none
    try ProviderCatalog(document: corrected, credentials: .unavailable).validate(.init(provider: "openai", model: "gpt-5.4", effort: "high"))
    #expect(try ModelsDocument(json: JSONEncoder().encode(corrected)) == corrected)
  }

  @Test func anthropicNoReplayAcceptsEveryListedEffort() throws {
    for dialect in [ModelsDocument.Dialect.anthropic, .claude] {
      for explicit in [true, false] {
        let thinking = ModelsDocument.Model(maxInput: 1000, maxOutput: 100, efforts: ["none", "high"], defaultEffort: "none")
        let provider = ModelsDocument.Provider(dialect: dialect, baseURL: URL(string: "https://proxy.test")!, opaqueReplay: explicit ? ModelsDocument.OpaqueReplay.none : nil, models: ["model": thinking])
        let document = ModelsDocument(providers: ["proxy": provider])
        #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
        let catalog = ProviderCatalog(document: document, credentials: .unavailable)
        try catalog.validate(.init(provider: "proxy", model: "model", effort: "high"))
        try catalog.validate(.init(provider: "proxy", model: "model", effort: "none"))
      }
    }
  }

  @Test func oidcIdentityStableAcrossJWTRefreshButIssuerAndAuthChangeRotate() async throws {
    var document = try ModelsDocument(json: fixtureJSON)
    document.providers["openai"]?.auth = .oidc
    func catalog(issuer: String, token: String) -> ProviderCatalog {
      ProviderCatalog(document: document, credentials: .unavailable, oidcToken: { _, _ in token }, oidcBindingIdentity: { _, _ in issuer })
    }
    let first = try await catalog(issuer: "issuer-one", token: "bearer-one").resolve(specifier, session: session)
    let fresh = try await catalog(issuer: "issuer-one", token: "bearer-two").resolve(specifier, session: session)
    #expect(first.replayScope != nil)
    #expect(first.replayScope == fresh.replayScope)
    #expect(first.socketIdentity != fresh.socketIdentity)
    let issuer = try await catalog(issuer: "issuer-two", token: "bearer-two").resolve(specifier, session: session)
    #expect(issuer.replayScope != first.replayScope)
    document.providers["openai"]?.auth = nil
    #expect(try await resolve(document).replayScope != first.replayScope)
  }

  @Test func oidcWithoutIdentityAndLegacyCredentialResolverCannotReplayOpaqueItems() async throws {
    var document = try ModelsDocument(json: fixtureJSON)
    let legacy = ProviderCatalog(document: document, credentials: .init { _ in .apiKey("fixture-key") })
    let resolved = try await legacy.resolve(specifier, session: session)
    #expect(resolved.replayScope == nil)
    #expect(try await legacy.resolve(specifier, session: session).bindingIdentity == resolved.bindingIdentity)
    document.providers["openai"]?.auth = .oidc
    let unknown = ProviderCatalog(document: document, credentials: .unavailable, oidcToken: { _, _ in "fixture-jwt" })
    #expect(try await unknown.resolve(specifier, session: session).replayScope == nil)
  }

  @Test func unverifiedOIDCUsesStableClaimsWithoutEnablingReplay() async throws {
    var document = try ModelsDocument(json: fixtureJSON)
    let provider = "unverified-jwt-refresh"
    document.providers[provider] = document.providers["openai"]
    document.providers[provider]?.auth = .oidc
    func catalog(issuer: String = "issuer", subject: String = "subject", audience: String = "audience", nonce: Int) -> ProviderCatalog {
      let payload = Data("{\"iss\":\"\(issuer)\",\"sub\":\"\(subject)\",\"aud\":\"\(audience)\",\"jti\":\"nonce-\(nonce)\",\"iat\":\(nonce)}".utf8).base64EncodedString()
      return ProviderCatalog(document: document, credentials: .unavailable, oidcToken: { _, _ in "header.\(payload).signature" })
    }
    let spec = ModelSpecifier(provider: provider, model: "gpt-5.4", effort: "high")
    let first = try await catalog(nonce: 1).resolve(spec, session: session)
    let refreshed = try await catalog(nonce: 2).resolve(spec, session: session)
    #expect(first.bindingIdentity == refreshed.bindingIdentity)
    #expect(first.replayScope == nil)
    #expect(refreshed.replayScope == nil)
    #expect(first.socketIdentity != refreshed.socketIdentity)
    let issuer = try await catalog(issuer: "other", nonce: 3).resolve(spec, session: session)
    #expect(issuer.bindingIdentity != refreshed.bindingIdentity)
    let subject = try await catalog(issuer: "other", subject: "other", nonce: 4).resolve(spec, session: session)
    #expect(subject.bindingIdentity != issuer.bindingIdentity)
    let audience = try await catalog(issuer: "other", subject: "other", audience: "other", nonce: 5).resolve(spec, session: session)
    #expect(audience.bindingIdentity != subject.bindingIdentity)
  }

  @Test func unverifiedOIDCAlternatingSessionSubjectsKeepIndependentEpochs() async throws {
    var document = try ModelsDocument(json: fixtureJSON)
    let provider = "unverified-interleaved-sessions"
    document.providers[provider] = document.providers["openai"]
    document.providers[provider]?.auth = .oidc
    let catalog = ProviderCatalog(document: document, credentials: .unavailable, oidcToken: { _, session in
      let payload = Data("{\"iss\":\"issuer\",\"sub\":\"\(session.rawValue)\",\"aud\":\"audience\",\"jti\":\"\(UUID().uuidString)\"}".utf8).base64EncodedString()
      return "header.\(payload).signature"
    })
    let spec = ModelSpecifier(provider: provider, model: "gpt-5.4", effort: "high")
    let a1 = try await catalog.resolve(spec, session: .init("session-a"))
    let b1 = try await catalog.resolve(spec, session: .init("session-b"))
    let a2 = try await catalog.resolve(spec, session: .init("session-a"))
    let b2 = try await catalog.resolve(spec, session: .init("session-b"))
    #expect(a1.bindingIdentity != b1.bindingIdentity)
    #expect(a1.bindingIdentity == a2.bindingIdentity)
    #expect(b1.bindingIdentity == b2.bindingIdentity)
    #expect(a2.replayScope == nil)
    #expect(b2.replayScope == nil)
  }

  @Test func unverifiedOIDCEpochCacheEvictsOnlyLeastRecentlyUsedIdentity() async {
    let identities = UnverifiedOIDCIdentities(capacity: 2)
    let a = await identities.epoch(provider: "provider", token: "a")
    let b = await identities.epoch(provider: "provider", token: "b")
    #expect(await identities.epoch(provider: "provider", token: "a") == a)
    _ = await identities.epoch(provider: "provider", token: "c")
    #expect(await identities.epoch(provider: "provider", token: "a") == a)
    #expect(await identities.epoch(provider: "provider", token: "b") != b)
  }

  @Test func oidcIdentityChangeDuringSigningFailsBeforeResolution() async throws {
    var document = try ModelsDocument(json: fixtureJSON)
    document.providers["openai"]?.auth = .oidc
    let identity = OIDCIdentityState()
    let catalog = ProviderCatalog(document: document, credentials: .unavailable, oidcToken: { _, _ in
      await identity.change()
      return "fixture-token"
    }, oidcBindingIdentity: { _, _ in await identity.value })
    await #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC replay identity changed while signing; resolve the provider again.")) {
      try await catalog.resolve(specifier, session: session)
    }
  }

  @Test func releasedDev114DecoderIgnoresOpaqueReplayKey() throws {
    let json = String(decoding: fixtureJSON, as: UTF8.self)
      .replacingOccurrences(of: "\"dialect\": \"responses\",", with: "\"dialect\": \"responses\", \"opaqueReplay\": \"none\",")
    let baseline = try JSONDecoder().decode([String: Dev114Provider].self, from: fixtureJSON)
    let extended = try JSONDecoder().decode([String: Dev114Provider].self, from: Data(json.utf8))
    #expect(extended == baseline)
  }
}

// Frozen synthesized Codable provider shape from wuhu/v0.1.0-dev.114.
private struct Dev114Provider: Decodable, Equatable {
  var dialect: ModelsDocument.Dialect
  var baseURL: URL
  var originator: String?
  var transport: ModelsDocument.Transport?
  var auth: ModelsDocument.Auth?
  var models: [String: ModelsDocument.Model]
}

private actor OIDCIdentityState {
  var value = "issuer-one"
  func change() { value = "issuer-two" }
}
