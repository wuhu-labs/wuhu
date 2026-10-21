@testable import CLIKit
import DeterministicDependencies
import JSONValue
import Testing

@Suite(.deterministicDependencies) struct ModelsVerbTests {
  @Test func seedIsValidJSONWithVerifiedModelIDs() throws {
    let seed = try #require(JSONValue.parse(WellKnownModels.seed))
    let providers = try #require(seed.object)
    #expect(Array(providers.keys).sorted() == ["anthropic", "codex", "deepseek", "openai"])
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
      "provider codex",
      "provider openai",
    ])

    let merged = try #require(merge.merged.object)
    #expect(merged["local"] != nil)
    let pro = merged["deepseek"]?.object?["models"]?.object?["deepseek-v4-pro"]?.object
    #expect(pro?["maxInput"] == .integer(99))
    #expect(merged["deepseek"]?.object?["models"]?.object?["deepseek-v4-flash"] != nil)
  }

  @Test func discoverySeparatesGroupsAndKeepsMemberOrderAndPolicy() throws {
    let groups = try #require(JSONValue.parse(#"{"work":{"kind":"group","members":[{"id":"second","provider":"b","model":"m"},{"id":"first","provider":"a","model":"n"}],"policy":{"type":"quotaAware","holdDownSeconds":1800}}}"#))
    #expect(renderedModels(providers: ["a": ["models": ["n": .object([:])]]], groups: groups) == "provider a\n  a/n\ngroup work {\"type\":\"quotaAware\",\"holdDownSeconds\":1800}\n  second: b/m\n  first: a/n\n")
  }

  @Test func mergeFromNothingIsTheSeed() throws {
    let basis = try #require(JSONValue.parse(WellKnownModels.seed))
    let merge = ModelsMerge(basis: basis, user: nil)
    #expect(merge.merged == basis)
    #expect(merge.added.count == 4)
  }

  @Test func prettyJSONRoundTrips() throws {
    let basis = try #require(JSONValue.parse(WellKnownModels.seed))
    let pretty = prettyJSON(basis)
    #expect(JSONValue.parse(pretty) == basis)
    #expect(pretty.contains("\n  \"anthropic\""))
  }

  @Test func parsesModelsUpdate() throws {
    #expect(try Command.parse(["models", "update"]) == .modelsUpdate)
    #expect(try Command.parse(["models"]) == .modelsList(json: false))
    #expect(try Command.parse(["models", "--json"]) == .modelsList(json: true))
    #expect(throws: (any Error).self) { try Command.parse(["models", "sync"]) }
  }
}

extension ModelsVerbTests {
  @Test func modelSyncPreservesReplayPolicyAndGroupEntries() throws {
    let basis = try #require(JSONValue.parse(WellKnownModels.seed))
    let group: JSONValue = ["kind": "group", "members": []]
    let user: JSONValue = [
      "anthropic": group,
      "openai": ["dialect": "responses", "baseURL": "https://proxy.test", "opaqueReplay": "none", "models": [:]],
      "deepseek": ["dialect": "anthropic", "baseURL": "https://api.deepseek.com/anthropic", "opaqueReplay": "affine", "models": [:]],
    ]
    let merge = ModelsMerge(basis: basis, user: user)
    #expect(merge.merged.object?["anthropic"] == group)
    #expect(merge.merged.object?["openai"]?.object?["opaqueReplay"] == .string("none"))
    #expect(merge.merged.object?["deepseek"]?.object?["opaqueReplay"] == .string("affine"))
  }
}
