import Credentials
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import SessionDomain
import Testing

private func imageCatalog(dialect: String, family: String?) throws -> ModelsDocument {
  let field = family.map { ",\"imageFamily\":\"\($0)\"" } ?? ""
  return try ModelsDocument(json: Data("""
  {"gateway":{"dialect":"\(dialect)","baseURL":"https://gateway.test"\(field),
    "models":{"model":{"maxInput":200000,"maxOutput":32000,"efforts":["high"],"defaultEffort":"high"}}}}
  """.utf8))
}

@Suite(.deterministicDependencies) struct ImageFamilyTests {
  @Test(arguments: ["anthropic", "responses", "codex"], [String?.none, "claude", "openAI"])
  func resolvedBudgetUsesImageFamily(dialect: String, family: String?) async throws {
    let document = try imageCatalog(dialect: dialect, family: family)
    let roundTripped = try ModelsDocument(json: JSONEncoder().encode(document))
    #expect(roundTripped == document)
    let catalog = ProviderCatalog(document: roundTripped, credentials: .init { _ in
      dialect == "codex" ? .chatGPT(accessToken: "fixture", accountID: "fixture") : .apiKey("fixture")
    })
    let resolved = try await catalog.resolve(.init(provider: "gateway", model: "model", effort: "high"), session: .init("test"))
    let expected: ImageLimits = (family ?? (dialect == "anthropic" ? "claude" : "openAI")) == "claude" ? .claude : .openAI
    #expect(resolved.budget.images == expected)
  }

  @Test func unknownFamilyIsAnInvalidProvider() throws {
    let document = try imageCatalog(dialect: "responses", family: "unknown")
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    do {
      try catalog.validate(.init(provider: "gateway", model: "model", effort: "high"))
      Issue.record("Unknown image family was accepted")
    } catch let CatalogError.invalidProvider(provider, _) {
      #expect(provider == "gateway")
    }
  }
}
