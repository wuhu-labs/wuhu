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

public enum WuhuModelCatalog {
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

  public static func models(for provider: WuhuProvider) -> [WuhuModelOption] {
    switch provider {
    case .openai:
      [
        .init(id: "gpt-5", displayName: "GPT-5"),
        .init(id: "gpt-5-codex", displayName: "GPT-5 Codex"),
        .init(id: "gpt-5.1", displayName: "GPT-5.1"),
        .init(id: "gpt-5.1-codex", displayName: "GPT-5.1 Codex"),
        .init(id: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex mini"),
        .init(id: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex max"),
        .init(id: "gpt-5.2", displayName: "GPT-5.2"),
        .init(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
      ]

    case .openaiCodex:
      [
        .init(id: "codex-mini-latest", displayName: "Codex mini (latest)"),
        .init(id: "gpt-5.1", displayName: "GPT-5.1"),
        .init(id: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex mini"),
        .init(id: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex max"),
        .init(id: "gpt-5.2", displayName: "GPT-5.2"),
        .init(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
        .init(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
      ]

    case .anthropic:
      [
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        .init(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"),
        .init(id: "claude-opus-4-5", displayName: "Claude Opus 4.5"),
        .init(id: "claude-haiku-4-6", displayName: "Claude Haiku 4.6"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(id: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
      ]
    }
  }

  public static func supportedReasoningEfforts(provider: WuhuProvider, modelID: String?) -> [ReasoningEffort] {
    guard let modelID, !modelID.isEmpty else { return [] }

    switch provider {
    case .anthropic:
      // Even though Opus 4.6 supports effort in some APIs, we don't surface it here yet.
      return []
    case .openai, .openaiCodex:
      guard modelID.hasPrefix("gpt-5") else { return [] }

      if modelID == "gpt-5.1-codex-mini" {
        return [.medium, .high]
      }

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
