import Foundation
import PiAI

public struct WuhuModelOption: Sendable, Hashable, Identifiable {
  public var id: String
  public var displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

/// Token limits for a known model.
public struct WuhuModelSpec: Sendable, Hashable {
  public var modelID: String
  public var maxInputTokens: Int
  public var maxOutputTokens: Int

  public init(modelID: String, maxInputTokens: Int, maxOutputTokens: Int) {
    self.modelID = modelID
    self.maxInputTokens = maxInputTokens
    self.maxOutputTokens = maxOutputTokens
  }

  /// Default max tokens to request, following the pi-coding-agent heuristic: maxOutputTokens / 3.
  public var defaultMaxTokens: Int {
    maxOutputTokens / 3
  }
}

// MARK: - Model alias resolution

public struct ResolvedModelAlias: Sendable, Hashable {
  public var apiModelID: String
  public var betaFeatures: [String]

  public init(apiModelID: String, betaFeatures: [String] = []) {
    self.apiModelID = apiModelID
    self.betaFeatures = betaFeatures
  }
}

public enum WuhuModelCatalog {
  // MARK: - Alias resolution

  private static let contextBeta1M = "context-1m-2025-08-07"

  private static let aliases: [String: ResolvedModelAlias] = [
    "claude-opus-4-6[1m]": .init(apiModelID: "claude-opus-4-6", betaFeatures: [contextBeta1M]),
    "claude-sonnet-4-6[1m]": .init(apiModelID: "claude-sonnet-4-6", betaFeatures: [contextBeta1M]),
  ]

  /// Resolves a user-facing model ID to its API model ID and any required beta headers.
  /// Returns an identity mapping (no beta features) for non-alias model IDs.
  public static func resolveAlias(_ modelID: String) -> ResolvedModelAlias {
    aliases[modelID] ?? .init(apiModelID: modelID)
  }

  // MARK: - Model specs (hardcoded token limits)

  /// All known model specs, keyed by model ID.
  public static let specs: [String: WuhuModelSpec] = {
    var table: [String: WuhuModelSpec] = [:]
    for spec in allSpecs {
      table[spec.modelID] = spec
    }
    return table
  }()

  private static let allSpecs: [WuhuModelSpec] = [
    // Anthropic — 200k input
    .init(modelID: "claude-opus-4-5", maxInputTokens: 200_000, maxOutputTokens: 128_000),
    .init(modelID: "claude-opus-4-6", maxInputTokens: 200_000, maxOutputTokens: 128_000),
    .init(modelID: "claude-sonnet-4-5", maxInputTokens: 200_000, maxOutputTokens: 64000),
    .init(modelID: "claude-sonnet-4-6", maxInputTokens: 200_000, maxOutputTokens: 64000),
    .init(modelID: "claude-haiku-4-5", maxInputTokens: 200_000, maxOutputTokens: 64000),

    // Anthropic — 1M input (beta)
    .init(modelID: "claude-opus-4-6[1m]", maxInputTokens: 1_000_000, maxOutputTokens: 128_000),
    .init(modelID: "claude-sonnet-4-6[1m]", maxInputTokens: 1_000_000, maxOutputTokens: 64000),

    // OpenAI — 400k input, 128k output
    .init(modelID: "gpt-5", maxInputTokens: 400_000, maxOutputTokens: 128_000),
    .init(modelID: "gpt-5.1", maxInputTokens: 400_000, maxOutputTokens: 128_000),
    .init(modelID: "gpt-5.2", maxInputTokens: 400_000, maxOutputTokens: 128_000),
    .init(modelID: "gpt-5-codex", maxInputTokens: 400_000, maxOutputTokens: 128_000),
    .init(modelID: "gpt-5.1-codex", maxInputTokens: 400_000, maxOutputTokens: 128_000),
    .init(modelID: "gpt-5.2-codex", maxInputTokens: 400_000, maxOutputTokens: 128_000),
  ]

  /// Fallback default max tokens when the model is not in the spec table.
  public static let fallbackDefaultMaxTokens = 16384

  /// Returns the default max tokens for a given model ID.
  /// Uses model's maxOutputTokens / 3 if known, otherwise `fallbackDefaultMaxTokens`.
  public static func defaultMaxTokens(for modelID: String) -> Int {
    specs[modelID]?.defaultMaxTokens ?? fallbackDefaultMaxTokens
  }

  // MARK: - Default model IDs

  public static func defaultModelID(for provider: WuhuProvider) -> String {
    switch provider {
    case .openai:
      "gpt-5.2-codex"
    case .anthropic:
      "claude-sonnet-4-5"
    case .openaiCodex:
      "codex-mini-latest"
    }
  }

  // MARK: - Model lists

  public static func models(for provider: WuhuProvider) -> [WuhuModelOption] {
    switch provider {
    case .openai:
      [
        .init(id: "gpt-5", displayName: "GPT-5"),
        .init(id: "gpt-5-codex", displayName: "GPT-5 Codex"),
        .init(id: "gpt-5.1", displayName: "GPT-5.1"),
        .init(id: "gpt-5.1-codex", displayName: "GPT-5.1 Codex"),
        .init(id: "gpt-5.2", displayName: "GPT-5.2"),
        .init(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
      ]

    case .openaiCodex:
      [
        .init(id: "codex-mini-latest", displayName: "Codex mini (latest)"),
        .init(id: "gpt-5.1", displayName: "GPT-5.1"),
        .init(id: "gpt-5.1-codex", displayName: "GPT-5.1 Codex"),
        .init(id: "gpt-5.2", displayName: "GPT-5.2"),
        .init(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
        .init(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
      ]

    case .anthropic:
      [
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        .init(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"),
        .init(id: "claude-opus-4-5", displayName: "Claude Opus 4.5"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(id: "claude-sonnet-4-6[1m]", displayName: "Claude Sonnet 4.6 (1M)"),
        .init(id: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
        .init(id: "claude-opus-4-6[1m]", displayName: "Claude Opus 4.6 (1M)"),
      ]
    }
  }

  // MARK: - Reasoning efforts

  public static func supportedReasoningEfforts(provider: WuhuProvider, modelID: String?) -> [ReasoningEffort] {
    guard let modelID, !modelID.isEmpty else { return [] }

    switch provider {
    case .anthropic:
      // Even though Opus 4.6 supports effort in some APIs, we don't surface it here yet.
      return []
    case .openai, .openaiCodex:
      guard modelID.hasPrefix("gpt-5") else { return [] }

      let supportsXhigh = modelID.hasPrefix("gpt-5.2") || modelID.hasPrefix("gpt-5.3")
      var efforts: [ReasoningEffort] = [.minimal, .low, .medium, .high]

      if supportsXhigh {
        efforts.append(.xhigh)
        // GPT-5.2/5.3 families don't support `minimal` (maps to `low`).
        efforts.removeAll { $0 == .minimal }
      }

      if modelID == "gpt-5.1" {
        efforts.removeAll { $0 == .xhigh }
      }

      return efforts
    }
  }
}
