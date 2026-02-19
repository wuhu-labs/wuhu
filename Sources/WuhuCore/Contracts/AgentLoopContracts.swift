import Foundation
import PiAI

// MARK: - Agent Behavior

/// Domain-specific feature that drives an ``AgentLoop``.
///
/// Owns persistence, inference, tool execution, and drain logic.
/// All IO methods persist to the database and return **actions** describing
/// what changed. The loop applies actions to in-memory state and emits
/// them as observation events.
///
/// ## Invariant
///
/// For every IO method that returns actions:
///
///     var state = /* current state */
///     let actions = try await behavior.someMethod(state: state)
///     for action in actions { behavior.apply(action, to: &state) }
///     let reloaded = try await behavior.loadState()
///     assert(state == reloaded)
///
/// The in-memory state after applying actions must equal a fresh load
/// from the database. This **free test** verifies persistence, action
/// generation, and the reducer in one assertion.
///
/// See <doc:ContractAgentLoop> for the full design rationale.
public protocol AgentBehavior: Sendable {
  // MARK: Associated Types

  /// Full state held by the loop.
  ///
  /// The loop treats state as an opaque value — it is owned and evolved by
  /// the behavior via ``apply(_:to:)``. The state must be equatable to support
  /// observation snapshots and invariant checks.
  associatedtype State: Sendable & Equatable

  /// Describes a persisted mutation. Applied to state by ``apply(_:to:)``,
  /// then emitted to observers.
  associatedtype CommittedAction: Sendable

  /// Describes an ephemeral streaming update (inference text delta, etc.).
  /// Not persisted, not applied to committed state.
  associatedtype StreamAction: Sendable

  /// Domain-specific commands from outside the loop (enqueue, cancel,
  /// change model, etc.).
  associatedtype ExternalAction: Sendable

  /// The result of executing a tool. Opaque to the loop — it just
  /// passes the value from ``executeToolCall(_:)`` to
  /// ``toolDidExecute(_:result:state:)``.
  associatedtype ToolResult: Sendable

  // MARK: State Management

  /// Placeholder state used before ``loadState()`` runs.
  ///
  /// The loop initializes synchronously, but real state is loaded async at
  /// startup. This value should be cheap and deterministic.
  static var emptyState: State { get }

  /// Load full state from the database. Called once on startup.
  func loadState() async throws -> State

  /// Pure reducer. Apply a committed action to in-memory state.
  ///
  /// - Important: Must be synchronous — no IO, no suspension.
  func apply(_ action: CommittedAction, to state: inout State)

  // MARK: External Actions

  /// Handle a command from outside the loop.
  ///
  /// Persists the effect and returns actions. For example, an enqueue
  /// command persists the queue item (and possibly flips `has_work`)
  /// and returns actions that update in-memory queue state.
  func handle(_ action: ExternalAction, state: State) async throws -> [CommittedAction]

  // MARK: Drain

  /// Atomically drain interrupt-priority items and write them to the
  /// transcript. Returns actions describing what was drained.
  ///
  /// Called at the **interrupt checkpoint** — after tool results are
  /// collected, before next inference.
  func drainInterruptItems(state: State) async throws -> [CommittedAction]

  /// Atomically drain turn-boundary items and write them to the
  /// transcript. Returns actions describing what was drained.
  ///
  /// Called at the **turn boundary** — the agent would otherwise go idle.
  func drainTurnItems(state: State) async throws -> [CommittedAction]

  // MARK: Inference

  /// Project current state into LLM input context.
  ///
  /// Pure function of state — no IO.
  func buildContext(state: State) -> Context

  /// Run inference. Yields streaming deltas to `stream` during execution.
  ///
  /// This is the only IO operation that is **not** persisted before
  /// returning. If the process crashes during inference, the loop
  /// retries on restart.
  func infer(
    context: Context,
    stream: AgentStreamSink<StreamAction>,
  ) async throws -> AssistantMessage

  // MARK: Persist Inference Results

  /// Persist the assistant's response and return actions.
  func persistAssistantEntry(
    _ message: AssistantMessage,
    state: State,
  ) async throws -> [CommittedAction]

  // MARK: Tool Lifecycle

  /// Record that a tool call is about to execute.
  ///
  /// Persists the status change for crash recovery: on restart,
  /// tool calls marked as started but not completed are treated as failed.
  func toolWillExecute(
    _ call: ToolCall,
    state: State,
  ) async throws -> [CommittedAction]

  /// Execute a tool call. Runs outside the serialized path (parallel).
  func executeToolCall(_ call: ToolCall) async throws -> ToolResult

  /// Persist a tool result and return actions.
  func toolDidExecute(
    _ call: ToolCall,
    result: ToolResult,
    state: State,
  ) async throws -> [CommittedAction]

  /// Persist an error for a tool call that threw during execution.
  func toolDidFail(
    _ call: ToolCall,
    error: any Error,
    state: State,
  ) async throws -> [CommittedAction]

  // MARK: Compaction

  /// Whether compaction should run after this inference.
  func shouldCompact(state: State, usage: Usage) -> Bool

  /// Perform compaction and return actions.
  func performCompaction(state: State) async throws -> [CommittedAction]

  // MARK: Crash Recovery

  /// Tool call IDs stuck in `.started` from a previous crash.
  func staleToolCallIDs(in state: State) -> [String]

  /// Inject an error result for a crash-interrupted tool call.
  func recoverStaleToolCall(
    id: String,
    state: State,
  ) async throws -> [CommittedAction]

  // MARK: Cold Start

  /// Whether the loaded state has pending work.
  func hasWork(state: State) -> Bool
}

// MARK: - Tool Call Status

/// Status of a tool call in the execution lifecycle.
public enum ToolCallStatus: String, Sendable, Hashable, Codable {
  case pending
  case started
  case completed
  case errored
}

// MARK: - Stream Sink

/// Push-based sink for streaming inference deltas into the loop's
/// event stream.
///
/// The behavior yields stream actions during inference. The loop
/// forwards them as ``AgentLoopEvent/streamDelta(_:)`` events to
/// observers.
public struct AgentStreamSink<Action: Sendable>: Sendable {
  public let yield: @Sendable (Action) -> Void

  public init(yield: @escaping @Sendable (Action) -> Void) {
    self.yield = yield
  }
}

// MARK: - Loop Events

/// Events emitted by the agent loop for observation.
///
/// Committed actions advance the persisted state. Stream events are
/// ephemeral — they are not persisted and do not advance the stable
/// version.
public enum AgentLoopEvent<CommittedAction: Sendable, StreamAction: Sendable>: Sendable {
  /// A persisted mutation was applied to state.
  case committed(CommittedAction)

  /// Inference streaming has begun.
  case streamBegan

  /// An ephemeral streaming delta.
  case streamDelta(StreamAction)

  /// Inference streaming has ended.
  case streamEnded
}

// MARK: - Observation

/// Gap-free observation of the agent loop's state and events.
///
/// Returned by ``AgentLoop/observe()``. The state snapshot and event
/// stream are registered atomically — no events are missed between
/// the snapshot and the first event on the stream.
public struct AgentLoopObservation<B: AgentBehavior>: Sendable {
  /// Current committed state at the time of observation.
  public var state: B.State

  /// Accumulated stream deltas if inference is in progress, nil otherwise.
  public var inflight: [B.StreamAction]?

  /// Live event stream from the point of observation.
  public var events: AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>

  public init(
    state: B.State,
    inflight: [B.StreamAction]?,
    events: AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>,
  ) {
    self.state = state
    self.inflight = inflight
    self.events = events
  }
}
