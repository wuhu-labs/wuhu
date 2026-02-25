import Testing
@testable import WuhuAPI

@Suite("WuhuModelCatalog – Model Spec Tests")
struct WuhuModelCatalogTests {
  // MARK: - Spec lookup

  @Test("Known Anthropic Opus models have 128k output, default max = 128k/3")
  func anthropicOpusSpecs() {
    for modelID in ["claude-opus-4-5", "claude-opus-4-6"] {
      let spec = WuhuModelCatalog.specs[modelID]
      #expect(spec != nil, "Expected spec for \(modelID)")
      #expect(spec?.maxInputTokens == 200_000)
      #expect(spec?.maxOutputTokens == 128_000)
      #expect(spec?.defaultMaxTokens == 128_000 / 3)
    }
  }

  @Test("Known Anthropic Sonnet/Haiku models have 64k output, default max = 64k/3")
  func anthropicSonnetHaikuSpecs() {
    for modelID in ["claude-sonnet-4-5", "claude-sonnet-4-6", "claude-haiku-4-5"] {
      let spec = WuhuModelCatalog.specs[modelID]
      #expect(spec != nil, "Expected spec for \(modelID)")
      #expect(spec?.maxInputTokens == 200_000)
      #expect(spec?.maxOutputTokens == 64000)
      #expect(spec?.defaultMaxTokens == 64000 / 3)
    }
  }

  @Test("Known OpenAI models have 400k input, 128k output, default max = 128k/3")
  func openAISpecs() {
    let models = ["gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5-codex", "gpt-5.1-codex", "gpt-5.2-codex"]
    for modelID in models {
      let spec = WuhuModelCatalog.specs[modelID]
      #expect(spec != nil, "Expected spec for \(modelID)")
      #expect(spec?.maxInputTokens == 400_000)
      #expect(spec?.maxOutputTokens == 128_000)
      #expect(spec?.defaultMaxTokens == 128_000 / 3)
    }
  }

  @Test("Unknown model returns fallback default max tokens")
  func unknownModelFallback() {
    let result = WuhuModelCatalog.defaultMaxTokens(for: "some-unknown-model-xyz")
    #expect(result == WuhuModelCatalog.fallbackDefaultMaxTokens)
    #expect(result == 16384)
  }

  @Test("defaultMaxTokens returns spec-based value for known model")
  func defaultMaxTokensKnown() {
    // Opus: 128k / 3 = 42666
    #expect(WuhuModelCatalog.defaultMaxTokens(for: "claude-opus-4-5") == 42666)
    // Sonnet: 64k / 3 = 21333
    #expect(WuhuModelCatalog.defaultMaxTokens(for: "claude-sonnet-4-5") == 21333)
    // OpenAI: 128k / 3 = 42666
    #expect(WuhuModelCatalog.defaultMaxTokens(for: "gpt-5.2-codex") == 42666)
  }

  // MARK: - Model list cleanup

  @Test("Anthropic model list does not contain haiku 4.6")
  func noHaiku46() {
    let models = WuhuModelCatalog.models(for: .anthropic)
    let ids = models.map(\.id)
    #expect(!ids.contains("claude-haiku-4-6"))
  }

  @Test("Anthropic model list contains expected models")
  func anthropicExpectedModels() {
    let models = WuhuModelCatalog.models(for: .anthropic)
    let ids = Set(models.map(\.id))
    #expect(ids.contains("claude-haiku-4-5"))
    #expect(ids.contains("claude-sonnet-4-5"))
    #expect(ids.contains("claude-opus-4-5"))
    #expect(ids.contains("claude-sonnet-4-6"))
    #expect(ids.contains("claude-opus-4-6"))
    #expect(ids.count == 5)
  }

  @Test("OpenAI model list does not contain mini/max variants")
  func noMiniMaxVariants() {
    let models = WuhuModelCatalog.models(for: .openai)
    let ids = models.map(\.id)
    #expect(!ids.contains("gpt-5.1-codex-mini"))
    #expect(!ids.contains("gpt-5.1-codex-max"))
  }

  @Test("OpenAI model list contains expected models")
  func openAIExpectedModels() {
    let models = WuhuModelCatalog.models(for: .openai)
    let ids = Set(models.map(\.id))
    #expect(ids.contains("gpt-5"))
    #expect(ids.contains("gpt-5-codex"))
    #expect(ids.contains("gpt-5.1"))
    #expect(ids.contains("gpt-5.1-codex"))
    #expect(ids.contains("gpt-5.2"))
    #expect(ids.contains("gpt-5.2-codex"))
    #expect(ids.count == 6)
  }

  // MARK: - Spec table coverage

  @Test("Every model in the spec table appears in at least one model list")
  func specTableCoverage() {
    let allListedIDs: Set<String> = {
      var ids = Set<String>()
      for provider in WuhuProvider.allCases {
        for model in WuhuModelCatalog.models(for: provider) {
          ids.insert(model.id)
        }
      }
      return ids
    }()

    for specID in WuhuModelCatalog.specs.keys {
      #expect(allListedIDs.contains(specID), "Spec for '\(specID)' not in any model list")
    }
  }
}
