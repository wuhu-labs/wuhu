#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MainHub.EventSources
import SessionDomain
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata
import enum WuhuAI.Tool
import struct WuhuAI.ToolCall

public struct InferenceRequest: Sendable {
  public var sessionID: SessionID
  public var attemptID: UUID
  public var generation: Int
  public var transcript: Transcript
  public var idleTimeout: Duration

  public init(
    sessionID: SessionID,
    attemptID: UUID,
    generation: Int,
    transcript: Transcript,
    idleTimeout: Duration = .seconds(120),
  ) {
    self.sessionID = sessionID
    self.attemptID = attemptID
    self.generation = generation
    self.transcript = transcript
    self.idleTimeout = idleTimeout
  }
}

public struct ToolInvocation: Sendable {
  public var sessionID: SessionID
  public var call: ToolCall
  public var state: ToolExecutionState
  /// True once the call is told to yield: an exec or a script then answers `running`. False when no yield will come.
  public var yielded: @Sendable () async -> Bool

  public init(sessionID: SessionID, call: ToolCall, state: ToolExecutionState, yielded: @escaping @Sendable () async -> Bool = { false }) {
    self.sessionID = sessionID
    self.call = call
    self.state = state
    self.yielded = yielded
  }
}

/// The binary's tools differ from the list the generation was given and the generation has not been told so: the step ends without an attempt, and the session cell writes `notice` before the next one. The stored list keeps being sent.
public struct ToolRosterChanged: Error, Equatable, Sendable {
  public static let source = SubscriptionID("tool-roster")

  public var notice: String

  /// Nil when no tool was added, removed or changed, or when `transcript` already carries this very notice.
  public init?(stored: [Tool], live: [Tool], told transcript: Transcript) {
    func name(_ tool: Tool) -> String {
      switch tool {
      case let .function(name, _, _): name
      case let .hosted(type): type
      }
    }
    let before: [String: Tool] = Dictionary(stored.map { (name($0), $0) }) { first, _ in first }
    let after: [String: Tool] = Dictionary(live.map { (name($0), $0) }) { first, _ in first }
    let added: [String] = live.map(name).filter { before[$0] == nil }
    let removed: [String] = stored.map(name).filter { after[$0] == nil }
    let changed: [String] = live.filter { tool in before[name(tool)].map { $0 != tool } ?? false }.map(name)
    let parts: [String] = [("Added", added), ("Removed", removed), ("Changed", changed)]
      .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1.joined(separator: ", "))." }
    guard !parts.isEmpty else { return nil }
    let notice = "The server was upgraded and its tools differ from the list this generation was given. \(parts.joined(separator: " ")) "
      + "Your list stays as it is until your next compaction, which brings the new one. Until then a call to a removed tool gets an error result, "
      + "and a changed tool takes what the server accepts now: if a call is refused, the error says what it expects."
    let told = transcript.items.contains { item in
      guard case let .notification(notification) = item else { return false }
      return notification.subscriptionID == Self.source && notification.content.text == notice
    }
    guard !told else { return nil }
    self.notice = notice
  }
}

public struct ReplayBoundaryRequired: Error, Sendable {
  public var binding: ReplayBinding
  public var budget: ContextBudget

  public init(binding: ReplayBinding, budget: ContextBudget) {
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
  /// The attempt's follow-up once it is the step's reply, with the transcript it ends.
  public var committed: @Sendable (AssistantEntry, Transcript) async -> Void

  public init(message: AssistantMessage, metadata: AssistantMessageMetadata, replayBinding: ReplayBinding? = nil, committed: @escaping @Sendable (AssistantEntry, Transcript) async -> Void = { _, _ in }) {
    self.message = message
    self.metadata = metadata
    self.replayBinding = replayBinding
    self.committed = committed
  }
}

public struct LoopConfig: Sendable {
  public var executeTool: @Sendable (ToolInvocation) async throws -> ToolOutcome
  public var inference: @Sendable (InferenceRequest) async throws -> InferenceReply
  // The compacted transcript and the target a compact call named, if any. A
  // throw with a target is the model's refusal: nothing folds.
  public var prepareCompaction: @Sendable (SessionID, Transcript, CompactionTarget?) async throws -> ModelRouteTransition?
  public var budget: @Sendable (SessionID) async -> ContextBudget
  // Fired when an interrupt cancels a mid-flight tool: the composition root
  // propagates the kill to the effector.
  public var killInterruptedTool: @Sendable (ToolInvocation) async -> Void
  public var invalidateInference: @Sendable (SessionID) async -> Void
  // The cancel ids of the work running for a session outside the loop
  // (`script.<id>`), listed in the `<session-state>` of a compaction.
  public var runningWork: @Sendable (SessionID) async throws -> [String]
  public var thresholds: CompactionThresholds
  /// Where a session's plain stream observations dial.
  public var sources: EventSources
  /// Takes each turn row a session's cell found different from its transcript.
  public var turnDifference: (@Sendable (TurnDifference) async -> Void)?

  public init(
    executeTool: @escaping @Sendable (ToolInvocation) async throws -> ToolOutcome,
    inference: @escaping @Sendable (InferenceRequest) async throws -> InferenceReply,
    budget: @escaping @Sendable (SessionID) async -> ContextBudget,
    prepareCompaction: @escaping @Sendable (SessionID, Transcript, CompactionTarget?) async throws -> ModelRouteTransition? = { _, _, _ in nil },
    killInterruptedTool: @escaping @Sendable (ToolInvocation) async -> Void = { _ in },
    invalidateInference: @escaping @Sendable (SessionID) async -> Void = { _ in },
    runningWork: @escaping @Sendable (SessionID) async throws -> [String] = { _ in [] },
    thresholds: CompactionThresholds = .init(),
    sources: EventSources = .unavailable,
    turnDifference: (@Sendable (TurnDifference) async -> Void)? = nil,
  ) {
    self.prepareCompaction = prepareCompaction
    self.executeTool = executeTool
    self.inference = inference
    self.budget = budget
    self.killInterruptedTool = killInterruptedTool
    self.invalidateInference = invalidateInference
    self.runningWork = runningWork
    self.thresholds = thresholds
    self.sources = sources
    self.turnDifference = turnDifference
  }
}
