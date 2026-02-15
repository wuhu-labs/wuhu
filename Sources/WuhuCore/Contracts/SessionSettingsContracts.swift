import Foundation
import PiAI

/// Snapshot of session-level settings that influence LLM requests.
public struct SessionSettingsSnapshot: Sendable, Hashable, Codable {
  public var effectiveModel: ModelSpecifier
  public var pendingModel: ModelSpecifier?

  public var effectiveReasoningEffort: ReasoningEffort?
  public var pendingReasoningEffort: ReasoningEffort?

  public init(
    effectiveModel: ModelSpecifier,
    pendingModel: ModelSpecifier? = nil,
    effectiveReasoningEffort: ReasoningEffort? = nil,
    pendingReasoningEffort: ReasoningEffort? = nil
  ) {
    self.effectiveModel = effectiveModel
    self.pendingModel = pendingModel
    self.effectiveReasoningEffort = effectiveReasoningEffort
    self.pendingReasoningEffort = pendingReasoningEffort
  }
}

/// A provider + model id, intentionally detached from provider-specific client configuration.
public struct ModelSpecifier: Sendable, Hashable, Codable {
  public var provider: ProviderID
  public var id: String

  public init(provider: ProviderID, id: String) {
    self.provider = provider
    self.id = id
  }
}

public struct ProviderID: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let openai = ProviderID(rawValue: "openai")
  public static let openaiCodex = ProviderID(rawValue: "openai-codex")
  public static let anthropic = ProviderID(rawValue: "anthropic")
}

/// Minimal execution status suitable for a read model / subscription.
public enum SessionExecutionStatus: String, Sendable, Hashable, Codable {
  case running
  case idle
  case stopped
}

public struct SessionStatusSnapshot: Sendable, Hashable, Codable {
  public var status: SessionExecutionStatus

  public init(status: SessionExecutionStatus) {
    self.status = status
  }
}

