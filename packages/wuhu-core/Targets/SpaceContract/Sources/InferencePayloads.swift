import Contract
import JSONValue

// What a prompt template knows of its session, as of the generation's start.
@Contract
public struct PromptSession: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let kind: SessionKindPayload
  public let model: String?
  public let tags: [String]
  public let home: String
}

// The caller's system prompt, rendered once for its generation, and the
// session its templates saw.
@Contract
public struct SessionPromptOutput: Codable, Equatable, Sendable {
  public let prompt: String
  public let session: PromptSession
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
