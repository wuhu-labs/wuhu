import enum Credentials.ChatGPTAuthError
import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import enum Fetch.FetchError
import Foundation
@testable import InferenceKit
import SessionDomain
import Testing
import WuhuAI

let fixtureJSON = Data("""
{
  "anthropic": {
    "dialect": "anthropic",
    "baseURL": "https://api.anthropic.com/v1",
    "models": {
      "claude-sonnet-5": {
        "maxInput": 200000, "maxOutput": 64000,
        "efforts": ["low", "medium", "high", "max"], "defaultEffort": "high"
      }
    }
  },
  "openai": {
    "dialect": "responses",
    "baseURL": "https://api.openai.com/v1",
    "models": {
      "gpt-5.4": {
        "maxInput": 400000, "maxOutput": 128000,
        "efforts": ["low", "medium", "high"], "defaultEffort": "medium",
        "headroomOverride": 32000
      }
    }
  },
  "deepseek": {
    "dialect": "anthropic",
    "baseURL": "https://api.deepseek.com/anthropic",
    "models": {
      "deepseek-v4-pro": {
        "maxInput": 131072, "maxOutput": 32768,
        "efforts": ["low", "medium", "high"], "defaultEffort": "high"
      }
    }
  },
  "codex": {
    "dialect": "codex",
    "baseURL": "https://chatgpt.com/backend-api/codex",
    "originator": "wuhu",
    "models": {
      "gpt-5.6-sol": {
        "maxInput": 272000, "maxOutput": 128000,
        "efforts": ["low", "medium", "high", "xhigh", "max"], "defaultEffort": "low"
      }
    }
  }
}
""".utf8)

func fixtureCatalog(
  credentials: CredentialResolver = CredentialResolver { _ in .apiKey("test-key") },
) throws -> ProviderCatalog {
  ProviderCatalog(document: try ModelsDocument(json: fixtureJSON), credentials: credentials)
}

private let chatGPTOnly = CredentialResolver { _ in
  .chatGPT(accessToken: "access.jwt", accountID: "acct-42")
}

@Suite struct CatalogTests {
  @Test func documentRoundTrips() throws {
    let document = try ModelsDocument(json: fixtureJSON)
    let reencoded = try ModelsDocument(json: JSONEncoder().encode(document))
    #expect(reencoded == document)
    #expect(document.providers.keys.sorted() == ["anthropic", "codex", "deepseek", "openai"])
    #expect(document.providers["codex"]?.originator == "wuhu")
  }

  @Test func claudeDialectCannotReachKernelInference() async throws {
    let document = try ModelsDocument(json: Data("""
    {"claude": {"dialect": "claude", "baseURL": "https://api.anthropic.com/v1",
      "models": {"opus": {"maxInput": 1000000, "maxOutput": 32000,
        "efforts": ["high"], "defaultEffort": "high"}}}}
    """.utf8))
    let catalog = ProviderCatalog(document: document, credentials: CredentialResolver { _ in
      Issue.record("kernel must refuse Claude Code before credential resolution")
      return .claudeCodeOAuth("fixture")
    })
    await #expect(throws: InferenceError.invalidInput(status: 422, body: "provider claude is run by the Claude Code executor, never by kernel inference")) {
      try await catalog.resolve(.init(provider: "claude", model: "opus", effort: "high"), session: SessionID("s"))
    }
  }

  @Test func anAutocompactWindowIsClaudeCodesAloneAndLeavesTheBudgetAlone() throws {
    let document = try ModelsDocument(json: Data("""
    {"claude": {"dialect": "claude", "baseURL": "https://api.anthropic.com/v1",
      "models": {"opus": {"maxInput": 1000000, "maxOutput": 32000,
        "efforts": ["high"], "defaultEffort": "high", "autocompactWindow": 233000}}}}
    """.utf8))
    let model = try #require(document.providers["claude"]?.models["opus"])
    #expect(model.autocompactWindow == 233_000)
    #expect(model.budget(.claude) == ContextBudget(maxInput: 1_000_000, maxOutput: 32000))
    #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
    #expect(try ModelsDocument(json: fixtureJSON).providers["anthropic"]?.models["claude-sonnet-5"]?.autocompactWindow == nil)
  }

  @Test func validationRejectsUnknownMembers() throws {
    let catalog = try fixtureCatalog()

    #expect(throws: CatalogError.unknownProvider("mistral")) {
      try catalog.validate(.init(provider: "mistral", model: "m", effort: "low"))
    }
    #expect(throws: CatalogError.unknownModel(provider: "anthropic", model: "claude-4")) {
      try catalog.validate(.init(provider: "anthropic", model: "claude-4", effort: "low"))
    }
    #expect(throws: CatalogError.unknownEffort(provider: "anthropic", model: "claude-sonnet-5", effort: "ultra")) {
      try catalog.validate(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "ultra"))
    }
    try catalog.validate(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "max"))
  }

  @Test func defaultSpecifierUsesDeclaredDefaultEffort() throws {
    let catalog = try fixtureCatalog()
    let spec = try catalog.defaultSpecifier(provider: "openai", model: "gpt-5.4")
    #expect(spec == ModelSpecifier(provider: "openai", model: "gpt-5.4", effort: "medium"))
  }

  @Test func budgetDerivation() async throws {
    let catalog = try fixtureCatalog()

    let anthropic = try await catalog.resolve(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "high"), session: SessionID("catalog-tests"))
    #expect(anthropic.budget == ContextBudget(maxInput: 200_000, maxOutput: 64000))
    #expect(anthropic.budget.usableTokens == 200_000 - 64000)

    let openai = try await catalog.resolve(.init(provider: "openai", model: "gpt-5.4", effort: "medium"), session: SessionID("catalog-tests"))
    #expect(openai.budget == ContextBudget(maxInput: 400_000, maxOutput: 128_000, headroomOverride: 32000, images: .openAI))
    #expect(openai.budget.usableTokens == 400_000 - 32000)
  }

  @Test func resolvesDialectEndpoints() async throws {
    let catalog = try fixtureCatalog()

    let deepseek = try await catalog.resolve(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high"), session: SessionID("catalog-tests"))
    #expect(deepseek.endpoint is DeepSeekAnthropicEndpoint)
    #expect(deepseek.endpoint.model == "deepseek-v4-pro")

    let anthropic = try await catalog.resolve(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "low"), session: SessionID("catalog-tests"))
    #expect((anthropic.endpoint as? AnthropicEndpoint)?.promptCache == .oneHour)

    let openai = try await catalog.resolve(.init(provider: "openai", model: "gpt-5.4", effort: "high"), session: SessionID("catalog-tests"))
    #expect((openai.endpoint as? OpenAIGPTEndpoint)?.promptCacheKey == "catalog-tests")
  }

  @Test func resolvesCodexEndpointFromChatGPTCredential() async throws {
    let catalog = try fixtureCatalog(credentials: chatGPTOnly)
    let codex = try await catalog.resolve(.init(provider: "codex", model: "gpt-5.6-sol", effort: "xhigh"), session: SessionID("catalog-tests"))
    let endpoint = try #require(codex.endpoint as? OpenAICodexEndpoint)
    #expect(endpoint.providerID == "openai-codex")
    #expect(endpoint.jwt == "access.jwt")
    #expect(endpoint.chatgptAccountID == "acct-42")
    #expect(endpoint.originator == "wuhu")
    #expect(endpoint.baseURL == URL(string: "https://chatgpt.com/backend-api/codex"))
  }

  @Test func codexEndpointCarriesTheSessionAsItsCacheAffinity() async throws {
    let catalog = try fixtureCatalog(credentials: chatGPTOnly)
    let codex = try await catalog.resolve(
      .init(provider: "codex", model: "gpt-5.6-sol", effort: "xhigh"),
      session: SessionID("broom-happy-crane"),
    )
    let endpoint = try #require(codex.endpoint as? OpenAICodexEndpoint)
    #expect(endpoint.sessionID == "broom-happy-crane")
  }

  @Test func resolveRequiresCredential() async throws {
    let catalog = try fixtureCatalog(credentials: .unavailable)
    await #expect(throws: InferenceError.invalidInput(
      status: 401,
      body: CatalogError.missingCredential(provider: "deepseek").description,
    )) {
      try await catalog.resolve(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high"), session: SessionID("catalog-tests"))
    }
  }

  @Test func resolveRejectsMismatchedCredentialKind() async throws {
    let apiKeyed = try fixtureCatalog()
    await #expect(throws: InferenceError.invalidInput(
      status: 401,
      body: CatalogError.credentialMismatch(provider: "codex").description,
    )) {
      try await apiKeyed.resolve(.init(provider: "codex", model: "gpt-5.6-sol", effort: "low"), session: SessionID("catalog-tests"))
    }
    let chatGPTKeyed = try fixtureCatalog(credentials: chatGPTOnly)
    await #expect(throws: InferenceError.invalidInput(
      status: 401,
      body: CatalogError.credentialMismatch(provider: "anthropic").description,
    )) {
      try await chatGPTKeyed.resolve(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "low"), session: SessionID("catalog-tests"))
    }
  }

  @Test func resolveRejectsUnknownMemberAsTerminal() async throws {
    let catalog = try fixtureCatalog()
    await #expect(throws: InferenceError.invalidInput(
      status: 422,
      body: CatalogError.unknownModel(provider: "anthropic", model: "claude-4").description,
    )) {
      try await catalog.resolve(.init(provider: "anthropic", model: "claude-4", effort: "low"), session: SessionID("catalog-tests"))
    }
  }

  // The resolution hop runs inside the loop's retry, so its failures have to
  // arrive in the loop's vocabulary or a network blip parks the session.
  @Test func resolveRestatesCredentialTransportFailureAsTransport() async throws {
    let unreachable = CredentialResolver { _ in
      throw ChatGPTAuthError.unreachable(hop: "auth.openai.com to refresh ChatGPT credentials", kind: .connectTimeout)
    }
    let catalog = try fixtureCatalog(credentials: unreachable)
    await #expect(throws: InferenceError.transport(.connectTimeout)) {
      try await catalog.resolve(.init(provider: "codex", model: "gpt-5.6-sol", effort: "low"), session: SessionID("catalog-tests"))
    }
  }

  @Test func resolveNormalizesBareFetchFailures() async throws {
    let flaky = CredentialResolver { _ in
      throw FetchError.transportFailure(kind: .connectionClosed)
    }
    let catalog = try fixtureCatalog(credentials: flaky)
    await #expect(throws: InferenceError.transport(.connectionClosed)) {
      try await catalog.resolve(.init(provider: "codex", model: "gpt-5.6-sol", effort: "low"), session: SessionID("catalog-tests"))
    }
  }

  @Test func resolveKeepsExpiredLoginTerminalAndActionable() async throws {
    let expired = CredentialResolver { _ in
      throw ChatGPTAuthError.loginRequired(detail: "refresh returned 401")
    }
    let catalog = try fixtureCatalog(credentials: expired)
    await #expect(throws: InferenceError.invalidInput(
      status: 401,
      body: ChatGPTAuthError.loginRequired(detail: "refresh returned 401").description,
    )) {
      try await catalog.resolve(.init(provider: "codex", model: "gpt-5.6-sol", effort: "low"), session: SessionID("catalog-tests"))
    }
  }
}
