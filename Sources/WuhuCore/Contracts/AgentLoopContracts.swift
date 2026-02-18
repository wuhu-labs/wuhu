import Foundation

// MARK: - Session Persistence

/// IO boundary for session state.
///
/// The ``SessionAgent`` actor delegates all durable operations to this protocol.
/// Implementations provide the actual storage — SQLite for production,
/// in-memory arrays for tests.
///
/// ## Atomicity Requirements
///
/// Every method MUST be atomic and crash-safe. If the process crashes mid-call,
/// the database must remain in a consistent state — either the operation fully
/// committed or it didn't.
///
/// In particular:
/// - ``toolDidExecute(toolCallID:output:sessionID:)`` flips the tool-call status AND
///   writes the transcript entry in a **single transaction**. Partial writes
///   (status flipped but entry missing, or vice versa) are not recoverable.
/// - ``materialize(_:)`` moves items from queue tables to the transcript table
///   in a **single transaction**.
///
/// See <doc:ContractAgentLoop> for the design rationale.
public protocol SessionPersistence: Sendable {

  // MARK: Lifecycle

  /// Record the session as actively running. Used for crash recovery:
  /// on restart, sessions marked running are resumed.
  func markRunning(_ sessionID: SessionID) async throws

  /// Record the session as idle.
  func markIdle(_ sessionID: SessionID) async throws

  // MARK: State Loading

  /// Load full session state from the database.
  ///
  /// Called once when the ``SessionAgent`` is started. After this point,
  /// the store serves reads from memory.
  func loadState(_ sessionID: SessionID) async throws -> SessionState

  // MARK: Queue Operations

  /// Insert a queue item. The item is durable after this returns.
  func insertQueueItem(_ item: UserQueuePendingItem, lane: UserQueueLane) async throws

  /// Insert a system-urgent queue item.
  func insertSystemItem(_ item: SystemUrgentPendingItem) async throws

  /// Cancel a queue item that has not yet been materialized.
  func cancelQueueItem(_ id: QueueItemID, lane: UserQueueLane) async throws

  // MARK: Materialization

  /// Move queued items into the transcript in a single transaction.
  ///
  /// After this call, the items no longer exist in the queue tables and
  /// appear as transcript entries. This is the checkpoint operation.
  func materialize(_ items: [MaterializeRequest]) async throws

  // MARK: Transcript

  /// Persist the assistant's response to the transcript.
  ///
  /// Returns the assigned entry ID.
  func appendAssistantEntry(_ output: AgentInferenceOutput, sessionID: SessionID) async throws -> TranscriptEntryID

  // MARK: Tool Execution Bookkeeping

  /// Record that a tool execution has started.
  ///
  /// On crash recovery, tool calls marked as started but not completed
  /// are treated as failed (error result injected).
  func toolWillExecute(toolCallID: String, sessionID: SessionID) async throws

  /// Persist a tool result to the transcript.
  ///
  /// **Must be a single transaction**: flips the tool-call status to completed
  /// AND inserts the transcript entry atomically.
  func toolDidExecute(toolCallID: String, output: AgentToolOutput, sessionID: SessionID) async throws -> TranscriptEntryID

  // MARK: Compaction

  /// Perform compaction: summarize a segment of history and append the
  /// compaction entry. See <doc:ContractSession> for compaction semantics.
  func performCompaction(sessionID: SessionID) async throws
}

// MARK: - Session State

/// Plain data struct holding all session state.
///
/// This is a value type — fields only, no logic. The ``SessionAgent`` actor
/// holds one as `private(set) var state`. Policy decisions (what to
/// materialize, how to build context, when to compact) live on
/// ``SessionPolicy``, not here.
///
/// Also used as the return type of ``SessionPersistence/loadState(_:)``.
public struct SessionState: Sendable {
  public var transcript: [TranscriptItem]
  public var toolCallStatus: [String: ToolCallStatus]
  public var systemQueue: [SystemUrgentPendingItem]
  public var steerQueue: [UserQueuePendingItem]
  public var followUpQueue: [UserQueuePendingItem]

  public init(
    transcript: [TranscriptItem],
    toolCallStatus: [String: ToolCallStatus],
    systemQueue: [SystemUrgentPendingItem],
    steerQueue: [UserQueuePendingItem],
    followUpQueue: [UserQueuePendingItem]
  ) {
    self.transcript = transcript
    self.toolCallStatus = toolCallStatus
    self.systemQueue = systemQueue
    self.steerQueue = steerQueue
    self.followUpQueue = followUpQueue
  }

  public static let empty = SessionState(
    transcript: [], toolCallStatus: [:],
    systemQueue: [], steerQueue: [], followUpQueue: []
  )
}

// MARK: - Session Policy

/// Decision logic for the agent loop.
///
/// All methods are pure functions of the current ``SessionState`` (and
/// inference output where relevant). The ``SessionAgent`` calls these to
/// decide **what** to do; it handles **when** and **safely** itself.
///
/// > Implementation note: LLM agents should implement this protocol.
/// > The concurrency and persistence story is handled by ``SessionAgent``
/// > and ``SessionPersistence`` — this protocol is where the actual
/// > agent behavior lives. Implementors do not need to reason about
/// > serialization, crash recovery, or persistence ordering.
public protocol SessionPolicy: Sendable {

  /// Which tool call IDs are stuck in `.started` from a previous crash.
  func staleToolCallIDs(in state: SessionState) -> [String]

  /// Build an error result to inject for a crash-interrupted tool call.
  func crashRecoveryOutput(toolCallID: String) -> AgentToolOutput

  /// Determine which queued items should materialize into the transcript
  /// at this checkpoint. Encapsulates steer-vs-follow-up priority logic.
  func materializationRequests(for state: SessionState) -> [MaterializeRequest]

  /// Project the transcript into LLM input context.
  func buildContext(for state: SessionState) -> AgentLoopContext

  /// Run inference.
  func infer(context: AgentLoopContext) async throws -> AgentInferenceOutput

  /// Execute a single tool call. May be called concurrently for parallel tools.
  func execute(_ call: AgentToolCall) async throws -> AgentToolOutput

  /// Whether compaction should run after this inference.
  func shouldCompact(state: SessionState, usage: AgentLoopUsage) -> Bool
}

/// Status of a tool call in the execution lifecycle.
public enum ToolCallStatus: String, Sendable, Hashable, Codable {
  case pending
  case started
  case completed
  case errored
}

/// A request to materialize a queued item into the transcript.
public struct MaterializeRequest: Sendable {
  public var queueItemID: QueueItemID
  public var lane: MaterializeLane
  public var transcriptEntry: TranscriptItem

  public init(queueItemID: QueueItemID, lane: MaterializeLane, transcriptEntry: TranscriptItem) {
    self.queueItemID = queueItemID
    self.lane = lane
    self.transcriptEntry = transcriptEntry
  }
}

public enum MaterializeLane: String, Sendable, Hashable, Codable {
  case system
  case steer
  case followUp
}

// MARK: - Context

/// LLM input context built from the transcript.
public struct AgentLoopContext: Sendable {
  public var systemPrompt: String
  public var entries: [AgentLoopContextEntry]

  public init(systemPrompt: String, entries: [AgentLoopContextEntry]) {
    self.systemPrompt = systemPrompt
    self.entries = entries
  }
}

/// A transcript entry projected for LLM input. Always carries an entry ID.
public struct AgentLoopContextEntry: Sendable {
  public var id: TranscriptEntryID
  public var message: MessageEntry

  public init(id: TranscriptEntryID, message: MessageEntry) {
    self.id = id
    self.message = message
  }
}

// MARK: - Inference Output

/// Output from a single inference call.
public struct AgentInferenceOutput: Sendable {
  public var text: String?
  public var toolCalls: [AgentToolCall]
  public var usage: AgentLoopUsage

  public init(text: String?, toolCalls: [AgentToolCall], usage: AgentLoopUsage) {
    self.text = text
    self.toolCalls = toolCalls
    self.usage = usage
  }
}

/// A tool call from the assistant's response.
public struct AgentToolCall: Sendable, Hashable {
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
public struct AgentToolOutput: Sendable {
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

/// A tool that the agent loop can execute.
public protocol AgentTool: Sendable {
  var name: String { get }

  func execute(callID: String, arguments: String) async throws -> AgentToolOutput
}

// MARK: - Usage

/// Token usage from an inference call, for compaction decisions.
public struct AgentLoopUsage: Sendable {
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

/// Events emitted by the agent loop for observation (UI, SSE).
///
/// Streaming events (inference deltas) are ephemeral and not persisted.
/// Committed events (entry appended, checkpoint materialized) advance stable state.
public enum AgentLoopEvent: Sendable {
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
