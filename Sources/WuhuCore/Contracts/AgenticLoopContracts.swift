import Foundation

// MARK: - Store Protocol

/// Persistence and state boundary for the agentic loop.
///
/// Each session has a single owner that manages state. The agentic loop calls
/// into this protocol at each state transition. Implementations decide how to
/// persist: SQLite for production, in-memory arrays for tests.
///
/// See the ContractAgenticLoop design article for the full state machine.
public protocol AgenticLoopStore: Sendable {

  // MARK: Lifecycle

  /// Mark the session as actively executing. Persisted for crash recovery.
  func markRunning() async throws

  /// Mark the session as idle (no pending work).
  func markIdle() async throws

  // MARK: Context

  /// Build the LLM input context by projecting the current transcript.
  ///
  /// Applies compaction boundaries, filters to message-eligible entries,
  /// and assembles the context window.
  func buildContext() async throws -> AgenticLoopContext

  // MARK: Checkpoint Materialization

  /// Drain system and steer lanes at a steer checkpoint.
  ///
  /// Moves queued items into the transcript in a single transaction.
  /// Items are ordered by enqueue timestamp across lanes.
  func drainSteer() async throws -> [TranscriptItem]

  /// Drain the follow-up lane at a follow-up checkpoint.
  ///
  /// Same transactional guarantee as `drainSteer`.
  func drainFollowUp() async throws -> [TranscriptItem]

  // MARK: Persistence

  /// Persist the assistant's response to the transcript.
  ///
  /// Called immediately after inference completes, before any tool execution.
  func appendAssistantEntry(_ output: AgenticInferenceOutput) async throws -> TranscriptEntryID

  /// Record that a tool execution has started (for crash recovery).
  ///
  /// Non-idempotent tools that were started but not completed on crash
  /// will receive an error result on restart instead of being retried.
  func toolWillExecute(toolCallID: String, idempotent: Bool) async throws

  /// Persist a tool result to the transcript.
  func toolDidExecute(toolCallID: String, output: AgenticToolOutput) async throws -> TranscriptEntryID

  // MARK: Compaction

  /// Evaluate whether compaction should be triggered given token usage.
  func shouldCompact(usage: AgenticLoopUsage) async -> Bool

  /// Perform compaction: summarize a prefix of history and append the result.
  func performCompaction() async throws

  // MARK: Events

  /// Emit a loop event to subscribers. Streaming events are ephemeral.
  func emit(_ event: AgenticLoopEvent) async
}

// MARK: - Context

/// LLM input context built from the transcript.
public struct AgenticLoopContext: Sendable {
  public var systemPrompt: String
  public var entries: [AgenticLoopContextEntry]

  public init(systemPrompt: String, entries: [AgenticLoopContextEntry]) {
    self.systemPrompt = systemPrompt
    self.entries = entries
  }
}

/// A transcript entry projected for LLM input. Always carries an entry ID.
public struct AgenticLoopContextEntry: Sendable {
  public var id: TranscriptEntryID
  public var message: MessageEntry

  public init(id: TranscriptEntryID, message: MessageEntry) {
    self.id = id
    self.message = message
  }
}

// MARK: - Inference Output

/// Output from a single inference call, as seen by the agentic loop.
public struct AgenticInferenceOutput: Sendable {
  public var text: String?
  public var toolCalls: [AgenticToolCall]
  public var usage: AgenticLoopUsage

  public init(text: String?, toolCalls: [AgenticToolCall], usage: AgenticLoopUsage) {
    self.text = text
    self.toolCalls = toolCalls
    self.usage = usage
  }
}

/// A tool call from the assistant's response.
public struct AgenticToolCall: Sendable, Hashable {
  public var id: String
  public var name: String
  public var arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

// MARK: - Tool Output

/// The result of executing a tool.
public struct AgenticToolOutput: Sendable {
  public var toolCallID: String
  public var content: String
  public var isError: Bool

  public init(toolCallID: String, content: String, isError: Bool) {
    self.toolCallID = toolCallID
    self.content = content
    self.isError = isError
  }
}

// MARK: - Tool Protocol

/// A tool that the agentic loop can execute.
public protocol AgenticTool: Sendable {
  var name: String { get }
  var isIdempotent: Bool { get }

  func execute(callID: String, arguments: String) async throws -> AgenticToolOutput
}

// MARK: - Usage

/// Token usage from an inference call, for compaction decisions.
public struct AgenticLoopUsage: Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var contextLimit: Int

  public init(inputTokens: Int, outputTokens: Int, contextLimit: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.contextLimit = contextLimit
  }
}

// MARK: - Events

/// Events emitted by the agentic loop for observation (UI, SSE).
///
/// Streaming events (inference deltas) are ephemeral and not persisted.
/// Committed events (entry appended, checkpoint materialized) advance stable state.
public enum AgenticLoopEvent: Sendable {
  // Lifecycle
  case started
  case idle

  // Inference
  case inferenceStarted
  case inferenceDelta(String)
  case inferenceCompleted(entryID: TranscriptEntryID)

  // Tool execution
  case toolStarted(toolCallID: String, name: String)
  case toolCompleted(toolCallID: String, entryID: TranscriptEntryID)

  // Checkpoints
  case steerMaterialized([TranscriptEntryID])
  case followUpMaterialized([TranscriptEntryID])

  // Compaction
  case compactionStarted
  case compactionCompleted
}
