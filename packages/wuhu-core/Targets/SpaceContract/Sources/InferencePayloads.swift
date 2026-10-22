import Contract
import JSONValue

// One AGENTS.md (or skill file) as the prompt renders it, at the session's
// prompt revision.
@Contract
public struct PromptSection: Codable, Equatable, Sendable {
  public let path: String
  public let text: String
}

// One scope of a session's prompt: its instruction sections and skills.
@Contract
public struct PromptScope: Codable, Equatable, Sendable {
  public let sections: [PromptSection]
  public let skills: [SessionHomeSkill]
}

// The caller's prompt home, frozen at its prompt revision: its group's root
// and its own home. The kernel lays these out after the fixed text it carries
// itself.
@Contract
public struct SessionPromptOutput: Codable, Equatable, Sendable {
  public let home: String
  public let group: String
  public let groupLayer: PromptScope
  public let homeLayer: PromptScope
}

@Contract
public struct InferenceUsageInput: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheReadTokens: Int
  public let cacheWriteTokens: Int
  public let reasoningTokens: Int?
  public let totalTokens: Int
}

// One inference attempt the worker ran for the bearer's session. id names the
// attempt: reporting it again records nothing. timestamp is epoch seconds;
// outcome is ok, networkError, httpError, timeout or cancelled.
@Contract
public struct InferenceReportInput: Codable, Equatable, Sendable {
  public let id: String
  public let timestamp: Double
  public let provider: String
  public let model: String
  public let servedModel: String?
  public let effort: String
  public let outcome: String
  public let errorKind: String?
  public let status: Int?
  public let ttftMs: Int?
  public let durationMs: Int
  public let usage: InferenceUsageInput?
}
