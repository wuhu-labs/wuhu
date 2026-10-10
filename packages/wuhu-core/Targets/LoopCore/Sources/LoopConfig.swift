#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata
import struct WuhuAI.ToolCall

public enum InferenceMode: Hashable, Sendable {
  case normal
  case forcedCompact
}

public struct InferenceRequest: Sendable {
  public var sessionID: SessionID
  public var attemptID: UUID
  public var transcript: Transcript
  public var mode: InferenceMode
  public var idleTimeout: Duration

  public init(
    sessionID: SessionID,
    attemptID: UUID,
    transcript: Transcript,
    mode: InferenceMode,
    idleTimeout: Duration = .seconds(120),
  ) {
    self.sessionID = sessionID
    self.attemptID = attemptID
    self.transcript = transcript
    self.mode = mode
    self.idleTimeout = idleTimeout
  }
}

public struct ToolInvocation: Sendable {
  public var sessionID: SessionID
  public var call: ToolCall
  public var state: ToolExecutionState

  public init(sessionID: SessionID, call: ToolCall, state: ToolExecutionState) {
    self.sessionID = sessionID
    self.call = call
    self.state = state
  }
}

public struct InferenceReply: Sendable {
  public var message: AssistantMessage
  public var metadata: AssistantMessageMetadata
  public var committed: @Sendable (AssistantEntry, Transcript) async -> Void

  public init(message: AssistantMessage, metadata: AssistantMessageMetadata, committed: @escaping @Sendable (AssistantEntry, Transcript) async -> Void = { _, _ in }) {
    self.message = message
    self.metadata = metadata
    self.committed = committed
  }
}

public struct CompactionResult: Sendable {
  public var summary: String
  public var preReads: [String]
  public var kept: Range<Int>?

  public init(summary: String, preReads: [String] = [], kept: Range<Int>? = nil) {
    self.summary = summary
    self.preReads = preReads
    self.kept = kept
  }
}

public struct EvictionPolicy: Sendable {
  public var idleTTL: Duration
  public var maxIdle: Int
  public var sweepInterval: Duration

  public init(
    idleTTL: Duration = .seconds(300),
    maxIdle: Int = 32,
    sweepInterval: Duration = .seconds(30),
  ) {
    self.idleTTL = idleTTL
    self.maxIdle = maxIdle
    self.sweepInterval = sweepInterval
  }
}

public struct LoopConfig: Sendable {
  public var executeTool: @Sendable (ToolInvocation) async throws -> ToolResultPayload
  public var inference: @Sendable (InferenceRequest) async throws -> InferenceReply
  public var compact: @Sendable (SessionID, Transcript) async throws -> CompactionResult
  public var budget: @Sendable (SessionID) async -> ContextBudget
  // Fired when an interrupt cancels a mid-flight tool: the composition root
  // propagates the kill to the effector (a crash-shaped cancellation never
  // reaches this seam, so crash-retry rejoin stays possible).
  public var killInterruptedTool: @Sendable (ToolInvocation) async -> Void
  public var invalidateInference: @Sendable (SessionID) async -> Void
  public var thresholds: CompactionThresholds
  public var archiveGrace: Duration
  public var eviction: EvictionPolicy

  public init(
    executeTool: @escaping @Sendable (ToolInvocation) async throws -> ToolResultPayload,
    inference: @escaping @Sendable (InferenceRequest) async throws -> InferenceReply,
    compact: @escaping @Sendable (SessionID, Transcript) async throws -> CompactionResult,
    budget: @escaping @Sendable (SessionID) async -> ContextBudget,
    killInterruptedTool: @escaping @Sendable (ToolInvocation) async -> Void = { _ in },
    invalidateInference: @escaping @Sendable (SessionID) async -> Void = { _ in },
    thresholds: CompactionThresholds = .init(),
    archiveGrace: Duration = .seconds(24 * 3600),
    eviction: EvictionPolicy = .init(),
  ) {
    self.executeTool = executeTool
    self.inference = inference
    self.compact = compact
    self.budget = budget
    self.killInterruptedTool = killInterruptedTool
    self.invalidateInference = invalidateInference
    self.thresholds = thresholds
    self.archiveGrace = archiveGrace
    self.eviction = eviction
  }
}
