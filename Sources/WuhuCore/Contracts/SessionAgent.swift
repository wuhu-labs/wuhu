import Foundation

/// Owns a single session's in-memory state and runs the agent loop.
///
/// All reads are served from memory. All mutations go through ``serialized(_:)``
/// which persists to SQLite first, then updates the in-memory ``state``.
///
/// The agent delegates all decisions to ``SessionPolicy`` (what to materialize,
/// how to build context, when to compact). It handles only the concurrency
/// story: lifecycle, serialization, and crash-safe persistence ordering.
///
/// ## Lifecycle
///
/// Call ``start()`` exactly once. It blocks for the session's lifetime,
/// waiting for signals from ``enqueue(message:lane:)`` to drive the loop.
/// Cancel the task running `start()` to tear down.
///
/// See <doc:ContractAgentLoop> for the full design rationale.
public actor SessionAgent {

  nonisolated let sessionID: SessionID
  nonisolated let persistence: any SessionPersistence
  nonisolated let policy: any SessionPolicy

  // MARK: State

  private(set) var state: SessionState = .empty

  // MARK: Serialization

  /// Task chain tail for ``serialized(_:)``. Do not touch directly.
  private var _tail: Task<Void, Never>?

  // MARK: Lifecycle

  private var started = false
  private var signal: AsyncStream<Void>.Continuation?

  public init(
    sessionID: SessionID,
    persistence: any SessionPersistence,
    policy: any SessionPolicy
  ) {
    self.sessionID = sessionID
    self.persistence = persistence
    self.policy = policy
  }

  // MARK: - Serialization

  /// Serialize an async mutation: copy state out, run work with `inout`,
  /// write state back. Each block completes fully before the next starts.
  ///
  /// The `@Sendable` closure receives `inout SessionState` — it can read
  /// and mutate the state freely, and call persistence methods via the
  /// captured `persistence` reference (which is `nonisolated let`).
  ///
  /// - Important: Work blocks must not call ``serialized(_:)`` (deadlock).
  private func serialized<T: Sendable>(
    _ work: @escaping @Sendable (inout SessionState) async throws -> T
  ) async throws -> T {
    let previous = _tail
    return try await withCheckedThrowingContinuation { cont in
      _tail = Task {
        _ = await previous?.result
        guard !Task.isCancelled else {
          cont.resume(throwing: CancellationError())
          return
        }
        do {
          var s = self.state
          let result = try await work(&s)
          self.state = s
          cont.resume(returning: result)
        } catch { cont.resume(throwing: error) }
      }
    }
  }

  // MARK: - Lifecycle

  /// Start the session. Blocks until cancelled or the signal stream ends.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started, "SessionAgent.start() called more than once")
    started = true
    defer { started = false }

    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    signal = continuation

    try await serialized { [db = persistence, sid = sessionID] s in
      s = try await db.loadState(sid)
    }

    if hasWork { signal?.yield(()) }

    for await _ in stream {
      try await serialized { [db = persistence, sid = sessionID] _ in
        try await db.markRunning(sid)
      }
      try await runUntilIdle()
    }
  }

  // MARK: - External API

  /// Enqueue a user message into the specified lane.
  ///
  /// Persist first, then update memory — serialized so the persist + memory
  /// update cannot interleave with the loop.
  public func enqueue(message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    let id = try await serialized { [db = persistence] s in
      let item = UserQueuePendingItem(
        id: QueueItemID(rawValue: UUID().uuidString),
        enqueuedAt: Date(),
        message: message
      )
      try await db.insertQueueItem(item, lane: lane)
      switch lane {
      case .steer: s.steerQueue.append(item)
      case .followUp: s.followUpQueue.append(item)
      }
      return item.id
    }
    signal?.yield(())
    return id
  }

  /// Cancel a previously enqueued message.
  public func cancel(id: QueueItemID, lane: UserQueueLane) async throws {
    try await serialized { [db = persistence] s in
      try await db.cancelQueueItem(id, lane: lane)
      switch lane {
      case .steer: s.steerQueue.removeAll { $0.id == id }
      case .followUp: s.followUpQueue.removeAll { $0.id == id }
      }
    }
  }

  // MARK: - Agent Loop

  /// Run the loop until idle: recover → (materialize → infer → tools → compact)*
  private func runUntilIdle() async throws {
    var hasToolResults = try await recoverStaleToolCalls()

    while true {
      let requests = policy.materializationRequests(for: state)
      if !requests.isEmpty {
        try await serialized { [db = persistence] s in
          try await db.materialize(requests)
          // TODO: s.applyMaterialization(requests)
        }
      }

      guard !requests.isEmpty || hasToolResults else { break }
      hasToolResults = false

      let context = policy.buildContext(for: state)
      let output = try await policy.infer(context: context)   // NOT serialized

      try await serialized { [db = persistence, sid = sessionID] s in
        let _ = try await db.appendAssistantEntry(output, sessionID: sid)
        // TODO: s.appendAssistantEntry(output)
      }

      if !output.toolCalls.isEmpty {
        try await executeToolCalls(output.toolCalls)
        hasToolResults = true
      }

      if policy.shouldCompact(state: state, usage: output.usage) {
        try await serialized { [db = persistence, sid = sessionID] s in
          try await db.performCompaction(sessionID: sid)
          // TODO: s.applyCompaction()
        }
      }
    }

    try await serialized { [db = persistence, sid = sessionID] _ in
      try await db.markIdle(sid)
    }
  }

  // MARK: - Crash Recovery

  /// Find tool calls stuck in `.started` and inject error results.
  private func recoverStaleToolCalls() async throws -> Bool {
    let staleIDs = policy.staleToolCallIDs(in: state)
    for callID in staleIDs {
      let output = policy.crashRecoveryOutput(toolCallID: callID)
      try await serialized { [db = persistence, sid = sessionID] s in
        let _ = try await db.toolDidExecute(
          toolCallID: callID, output: output, sessionID: sid
        )
        s.toolCallStatus[callID] = .errored
      }
    }
    return !staleIDs.isEmpty
  }

  // MARK: - Tool Execution

  /// Execute tool calls: mark started (serialized), run in parallel
  /// (NOT serialized), record results (serialized).
  private func executeToolCalls(_ calls: [AgentToolCall]) async throws {
    for call in calls {
      try await serialized { [db = persistence, sid = sessionID] s in
        try await db.toolWillExecute(toolCallID: call.id, sessionID: sid)
        s.toolCallStatus[call.id] = .started
      }
    }

    let results: [AgentToolOutput] = try await withThrowingTaskGroup(
      of: AgentToolOutput.self,
      returning: [AgentToolOutput].self
    ) { [policy] group in
      for call in calls {
        group.addTask {
          do { return try await policy.execute(call) }
          catch {
            return AgentToolOutput(
              toolCallID: call.id,
              content: "Tool error: \(error.localizedDescription)",
              isError: true
            )
          }
        }
      }
      var outputs: [AgentToolOutput] = []
      for try await output in group { outputs.append(output) }
      return outputs
    }

    for output in results {
      try await serialized { [db = persistence, sid = sessionID] s in
        let _ = try await db.toolDidExecute(
          toolCallID: output.toolCallID, output: output, sessionID: sid
        )
        s.toolCallStatus[output.toolCallID] = output.isError ? .errored : .completed
      }
    }
  }

  // MARK: - Helpers

  private var hasWork: Bool {
    !state.systemQueue.isEmpty || !state.steerQueue.isEmpty
      || !state.followUpQueue.isEmpty
      || state.toolCallStatus.values.contains(where: { $0 == .pending || $0 == .started })
  }
}
