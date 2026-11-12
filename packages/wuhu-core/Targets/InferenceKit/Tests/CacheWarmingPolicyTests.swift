import DeterministicDependencies
import Foundation
import InferenceKit
import ModelProviders
import Testing

@Suite(.deterministicDependencies) struct CacheWarmingPolicyTests {
  @Test func explicitOptInAndDefaultsRoundTrip() throws {
    var json = String(decoding: fixtureJSON, as: UTF8.self)
    #expect(try ModelsDocument(json: fixtureJSON).providers.values.allSatisfy { $0.models.values.allSatisfy { $0.cacheWarming == nil } })
    json = json.replacingOccurrences(of: "\"maxInput\": 200000", with: "\"cacheWarming\": {}, \"maxInput\": 200000")
    let document = try ModelsDocument(json: Data(json.utf8))
    #expect(document.providers["anthropic"]?.models["claude-sonnet-5"]?.cacheWarming == CacheWarmingPolicy())
    #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
  }

  @Test func lifetimeDecodesAndMustExceedTheInterval() throws {
    var json = String(decoding: fixtureJSON, as: UTF8.self)
    json = json.replacingOccurrences(of: "\"maxInput\": 200000", with: "\"cacheWarming\": {\"lifetimeSeconds\": 7200}, \"maxInput\": 200000")
    #expect(try ModelsDocument(json: Data(json.utf8)).providers["anthropic"]?.models["claude-sonnet-5"]?.cacheWarming?.lifetimeSeconds == 7200)
    #expect(CacheWarmingPolicy().lifetimeSeconds > CacheWarmingPolicy().intervalSeconds)
  }

  @Test(arguments: ["true", "null", "[]", "0", "{\"intervalSeconds\":0}", "{\"lifetimeSeconds\":3000}", "{\"intervalSeconds\":3600,\"lifetimeSeconds\":3600}", "{\"maxPings\":-1}", "{\"floorTokens\":0}", "{\"compactionThresholdTokens\":100000}", "{\"compactionGrowthTokens\":50000}", "{\"minimumRemainingPercent\":101}", "{\"maxPings\":1.5}", "{\"maxPings\":null}", "{\"typo\":20}"])
  func malformedPolicyIsTypedConfigError(_ value: String) throws {
    let json = String(decoding: fixtureJSON, as: UTF8.self).replacingOccurrences(of: "\"maxInput\": 200000", with: "\"cacheWarming\": \(value), \"maxInput\": 200000")
    do {
      let document = try ModelsDocument(json: Data(json.utf8))
      _ = try ProviderCatalog(document: document, credentials: .unavailable).validate(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "high"))
      Issue.record("accepted malformed policy: \(value)")
    } catch let error as CatalogError {
      guard case .invalidCacheWarming = error else { Issue.record("wrong config error: \(error)"); return }
    }
  }
}
