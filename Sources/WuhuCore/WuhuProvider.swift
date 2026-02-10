import PiAI

public enum WuhuProvider: String, Sendable, Codable, CaseIterable, Hashable {
  case openai
  case openaiCodex = "openai-codex"
  case anthropic

  public var piProvider: Provider {
    switch self {
    case .openai:
      .openai
    case .openaiCodex:
      .openaiCodex
    case .anthropic:
      .anthropic
    }
  }
}
