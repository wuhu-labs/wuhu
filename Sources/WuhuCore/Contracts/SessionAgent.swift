import Foundation

/// Owns a single session's in-memory state and runs the agent loop.
///
/// All reads are served from memory. All mutations persist to SQLite first
/// (via ``SessionPersistence``), then update in-memory state. A serial queue
/// ensures mutations never interleave across suspension points.
///
/// ## Lifecycle
///
/// Call ``start()`` exactly once. It blocks for the session's lifetime,
/// waiting for signals from ``enqueue(message:lane:)`` to drive the loop.
/// Cancel the task running `start()` to tear down.
///
/// See <doc:ContractAgentLoop> for the full design rationale.
public actor SessionAgent {

  private let sessionID: SessionID
  private let persistence: any SessionPersistence
  private let tools: [any AgentTool]

  // MARK: State

  private var transcript: [TranscriptItem] = []
  private var toolCallStatus: [String: ToolCallStatus] = [:]
  private var systemQueue: [SystemUrgentPendingItem] = []
  private var steerQueue: [UserQueuePendingItem] = []
  private var followUpQueue: [UserQueuePendingItem] = []

  // MARK: Lifecycle

  private var started = false
  private var signal: AsyncStream<Void>.Continuation?

  public init(sessionID: SessionID, persistence: any SessionPersistence, tools: [any AgentTool]) {
    self.sessionID = sessionID
    self.persistence = persistence
    self.tools = tools
  }

  /// Start the session. Blocks until cancelled or the signal stream ends.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started, "SessionAgent.start() called more than once")
    started = true
    defer { started = false }

    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    signal = continuation

    // Load state from database
    let state = try await persistence.loadState(sessionID)
    transcript = state.transcript
    toolCallStatus = state.toolCallStatus
    systemQueue = state.systemQueue
    steerQueue = state.steerQueue
    followUpQueue = state.followUpQueue

    // If there is pending work from a previous run, signal immediately
    if hasWork() { signal?.yield(()) }

    for await _ in stream {
      try await persistence.markRunning(sessionID)
      try await runUntilIdle()
      try await persistence.markIdle(sessionID)
    }
  }

  // MARK: - External API

  /// Enqueue a user message into the specified lane.
  public func enqueue(message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    let item = UserQueuePendingItem(
      id: QueueItemID(rawValue: UUID().uuidString),
      enqueuedAt: Date(),
      message: message
    )
    try await persistence.insertQueueItem(item, lane: lane)
    switch lane {
    case .steer: steerQueue.append(item)
    case .followUp: followUpQueue.append(item)
    }
    signal?.yield(())
    return item.id
  }

  /// Cancel a previously enqueued message.
  public func cancel(id: QueueItemID, lane: UserQueueLane) async throws {
    try await persistence.cancelQueueItem(id, lane: lane)
    switch lane {
    case .steer: steerQueue.removeAll { $0.id == id }
    case .followUp: followUpQueue.removeAll { $0.id == id }
    }
  }

  // MARK: - Loop

  private func runUntilIdle() async throws {
    // TODO: Implement — resume tool execution, materialize, infer, compact
  }

  private func hasWork() -> Bool {
    !systemQueue.isEmpty || !steerQueue.isEmpty || !followUpQueue.isEmpty
      || toolCallStatus.values.contains(where: { $0 == .pending || $0 == .started })
  }
}
