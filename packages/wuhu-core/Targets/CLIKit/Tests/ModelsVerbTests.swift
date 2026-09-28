@testable import CLIKit
import JSONValue
import Testing

@Suite struct ModelsVerbTests {
  @Test func seedIsValidJSONWithVerifiedModelIDs() throws {
    let seed = try #require(JSONValue.parse(WellKnownModels.seed))
    let providers = try #require(seed.object)
    #expect(Array(providers.keys).sorted() == ["anthropic", "claude", "codex", "deepseek", "openai"])
    let deepseek = try #require(providers["deepseek"]?.object?["models"]?.object)
    #expect(Array(deepseek.keys).sorted() == ["deepseek-v4-flash", "deepseek-v4-pro"])
    for (_, provider) in providers {
      for (_, model) in provider.object?["models"]?.object ?? [:] {
        let entry = try #require(model.object)
        #expect(entry["maxInput"]?.intValue != nil)
        #expect(entry["maxOutput"]?.intValue != nil)
        let efforts = try #require(entry["efforts"]?.array)
        let defaultEffort = try #require(entry["defaultEffort"])
        #expect(efforts.contains(defaultEffort))
      }
    }
  }

  @Test func mergeIsAdditiveAndUserEditsWin() throws {
    let basis = try #require(JSONValue.parse(WellKnownModels.seed))
    let user = JSONValue.parse("""
    {
      "deepseek": {
        "dialect": "anthropic",
        "baseURL": "https://api.deepseek.com/anthropic",
        "models": {
          "deepseek-v4-pro": {
            "maxInput": 99, "maxOutput": 9, "efforts": ["high"], "defaultEffort": "high"
          }
        }
      },
      "local": {
        "dialect": "anthropic",
        "baseURL": "http://localhost:9000",
        "models": {}
      }
    }
    """)

    let merge = ModelsMerge(basis: basis, user: user)
    #expect(merge.added.sorted() == [
      "model deepseek/deepseek-v4-flash",
      "provider anthropic",
      "provider claude",
      "provider codex",
      "provider openai",
    ])

    let merged = try #require(merge.merged.object)
    #expect(merged["local"] != nil)
    let pro = merged["deepseek"]?.object?["models"]?.object?["deepseek-v4-pro"]?.object
    #expect(pro?["maxInput"] == .integer(99))
    #expect(merged["deepseek"]?.object?["models"]?.object?["deepseek-v4-flash"] != nil)
  }

  @Test func mergeFromNothingIsTheSeed() throws {
    let basis = try #require(JSONValue.parse(WellKnownModels.seed))
    let merge = ModelsMerge(basis: basis, user: nil)
    #expect(merge.merged == basis)
    #expect(merge.added.count == 5)
  }

  @Test func prettyJSONRoundTrips() throws {
    let basis = try #require(JSONValue.parse(WellKnownModels.seed))
    let pretty = prettyJSON(basis)
    #expect(JSONValue.parse(pretty) == basis)
    #expect(pretty.contains("\n  \"anthropic\""))
  }

  @Test func parsesModelsUpdate() throws {
    #expect(try Command.parse(["models", "update"]) == .modelsUpdate)
    #expect(throws: (any Error).self) { try Command.parse(["models"]) }
    #expect(throws: (any Error).self) { try Command.parse(["models", "sync"]) }
  }
}
