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

public struct ReplayBoundaryRequired: Error, Sendable {
  public var binding: ReplayBinding
  public var budget: ContextBudget
  public var route: SessionModelRoute?
  public var expectedEpoch: String?

  public init(binding: ReplayBinding, budget: ContextBudget, route: SessionModelRoute? = nil, expectedEpoch: String? = nil) {
    self.route = route
    self.expectedEpoch = expectedEpoch
    self.binding = binding
    self.budget = budget
  }
}

public struct ModelRouteWaiting: Error, Sendable {
  public var retryAt: Date
  public init(retryAt: Date) { self.retryAt = retryAt }
}

public struct InferenceReply: Sendable {
  public var message: AssistantMessage
  public var metadata: AssistantMessageMetadata
  public var replayBinding: ReplayBinding?
  public var committed: @Sendable (AssistantEntry, Transcript) async -> Void

  public init(message: AssistantMessage, metadata: AssistantMessageMetadata, replayBinding: ReplayBinding? = nil, committed: @escaping @Sendable (AssistantEntry, Transcript) async -> Void = { _, _ in }) {
    self.message = message
    self.metadata = metadata
    self.replayBinding = replayBinding
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
  public var executeTool: @Sendable (ToolInvocation) async throws -> ToolOutcome
  public var inference: @Sendable (InferenceRequest) async throws -> InferenceReply
  public var compact: @Sendable (SessionID, Transcript) async throws -> CompactionResult
  // The compacted transcript and the target a compact call named, if any. A
  // throw with a target is the model's refusal: nothing folds.
  public var prepareCompaction: @Sendable (SessionID, Transcript, CompactionTarget?) async throws -> ModelRouteTransition?
  public var budget: @Sendable (SessionID) async -> ContextBudget
  // Fired when an interrupt cancels a mid-flight tool: the composition root
  // propagates the kill to the effector (a crash-shaped cancellation never
  // reaches this seam, so crash-retry rejoin stays possible).
  public var killInterruptedTool: @Sendable (ToolInvocation) async -> Void
  public var invalidateInference: @Sendable (SessionID) async -> Void
  public var allowCacheWarming: @Sendable (SessionID) async throws -> Bool
  public var scheduleWake: (@Sendable (SessionID, Date?) async throws -> Void)?
  // The cancel ids of the work running for a session outside the loop
  // (`script.<id>`), listed in the `<session-state>` of a compaction.
  public var runningWork: @Sendable (SessionID) async throws -> [String]
  public var thresholds: CompactionThresholds
  public var eviction: EvictionPolicy

  public init(
    executeTool: @escaping @Sendable (ToolInvocation) async throws -> ToolOutcome,
    inference: @escaping @Sendable (InferenceRequest) async throws -> InferenceReply,
    compact: @escaping @Sendable (SessionID, Transcript) async throws -> CompactionResult,
    budget: @escaping @Sendable (SessionID) async -> ContextBudget,
    prepareCompaction: @escaping @Sendable (SessionID, Transcript, CompactionTarget?) async throws -> ModelRouteTransition? = { _, _, _ in nil },
    killInterruptedTool: @escaping @Sendable (ToolInvocation) async -> Void = { _ in },
    invalidateInference: @escaping @Sendable (SessionID) async -> Void = { _ in },
    allowCacheWarming: @escaping @Sendable (SessionID) async throws -> Bool = { _ in true },
    scheduleWake: (@Sendable (SessionID, Date?) async throws -> Void)? = nil,
    runningWork: @escaping @Sendable (SessionID) async throws -> [String] = { _ in [] },
    thresholds: CompactionThresholds = .init(),
    eviction: EvictionPolicy = .init(),
  ) {
    self.prepareCompaction = prepareCompaction
    self.executeTool = executeTool
    self.inference = inference
    self.compact = compact
    self.budget = budget
    self.killInterruptedTool = killInterruptedTool
    self.invalidateInference = invalidateInference
    self.allowCacheWarming = allowCacheWarming
    self.scheduleWake = scheduleWake
    self.runningWork = runningWork
    self.thresholds = thresholds
    self.eviction = eviction
  }
}
