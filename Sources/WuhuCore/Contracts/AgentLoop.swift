import Foundation
import PiAI

/// Generic agent loop runtime, parameterized by an ``AgentBehavior``.
///
/// Owns in-memory state, serializes mutations, orchestrates the
/// drain → infer → tools → compact cycle. All domain-specific logic
/// lives on the behavior — the loop handles only **when** and **safely**.
///
/// ## Lifecycle
///
/// Call ``start()`` exactly once. It blocks for the session's lifetime,
/// waiting for signals to drive the loop. Cancel the task running
/// `start()` to tear down.
///
/// ## Observation
///
/// Call ``observe()`` to get a gap-free `(state, stream)` pair.
/// External commands go through ``send(_:)``.
///
/// See <doc:ContractAgentLoop> for the full design rationale.
public actor AgentLoop<B: AgentBehavior> {

  // MARK: Dependencies

  nonisolated let behavior: B

  // MARK: State

  private(set) var state: B.State
  private var inflight: [B.StreamAction]?

  // MARK: Serialization

  /// Task chain tail for ``serialized(_:)``. Do not touch directly.
  private var _tail: Task<Void, Never>?

  // MARK: Lifecycle

  private var started = false
  private var signal: AsyncStream<Void>.Continuation?

  // MARK: Observation

  private var observers: [UUID: AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>.Continuation] = [:]

  // MARK: Init

  public init(behavior: B) {
    self.behavior = behavior
    self.state = B.State.empty
  }

  // MARK: - Observation

  /// Observe the loop's state and events, gap-free.
  ///
  /// The snapshot and stream registration are atomic (no events are
  /// missed between the snapshot and the first stream event).
  public func observe() -> AgentLoopObservation<B> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AgentLoopEvent<B.CommittedAction, B.StreamAction>>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { [weak self] in await self?.removeObserver(id) }
    }
    return AgentLoopObservation(state: state, inflight: inflight, events: stream)
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }

  // MARK: - External Actions

  /// Send a domain-specific command into the loop.
  ///
  /// The behavior persists the effect and returns actions, which are
  /// applied to state and emitted to observers. The loop is woken
  /// afterward in case new work was enqueued.
  public func send(_ action: B.ExternalAction) async throws {
    try await serialized { [behavior] state in
      try await behavior.handle(action, state: state)
    }
    signal?.yield(())
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started, "AgentLoop.start() called more than once")
    started = true
    defer { started = false }

    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    signal = continuation

    state = try await behavior.loadState()

    if behavior.hasWork(state: state) {
      signal?.yield(())
    }

    for await _ in stream {
      try await runUntilIdle()
    }
  }

  // MARK: - Serialization

  /// Serialize a mutation: pass current state (by value) to the work
  /// closure, which does IO and returns actions. Actions are applied
  /// to state and emitted, atomically with respect to other serialized
  /// blocks.
  ///
  /// - Important: Work closures must not call ``serialized(_:)`` (deadlock).
  @discardableResult
  private func serialized(
    _ work: @escaping @Sendable (B.State) async throws -> [B.CommittedAction]
  ) async throws -> [B.CommittedAction] {
    let previous = _tail
    return try await withCheckedThrowingContinuation { cont in
      _tail = Task {
        _ = await previous?.result
        guard !Task.isCancelled else {
          cont.resume(throwing: CancellationError())
          return
        }
        do {
          let actions = try await work(self.state)
          for action in actions {
            self.behavior.apply(action, to: &self.state)
          }
          self.emitCommitted(actions)
          cont.resume(returning: actions)
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Agent Loop

  /// Run the loop until idle: recover → (drain → infer → tools → compact)*
  private func runUntilIdle() async throws {
    var hasToolResults = try await recoverStaleToolCalls()

    while true {
      // Interrupt checkpoint
      let interruptActions = try await serialized { [behavior] state in
        try await behavior.drainInterruptItems(state: state)
      }

      if interruptActions.isEmpty && !hasToolResults {
        // No interrupt work. Check turn boundary.
        let turnActions = try await serialized { [behavior] state in
          try await behavior.drainTurnItems(state: state)
        }
        if turnActions.isEmpty { break } // truly idle
      }

      hasToolResults = false

      // Inference
      let context = behavior.buildContext(state: state)
      let message = try await performInference(context: context)

      // Persist assistant entry
      try await serialized { [behavior] state in
        try await behavior.persistAssistantEntry(message, state: state)
      }

      // Tool calls
      let toolCalls = message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
      }

      if !toolCalls.isEmpty {
        try await executeToolCalls(toolCalls)
        hasToolResults = true
      }

      // Compaction
      if let usage = message.usage,
        behavior.shouldCompact(state: state, usage: usage)
      {
        try await serialized { [behavior] state in
          try await behavior.performCompaction(state: state)
        }
      }
    }
  }

  // MARK: - Inference (with streaming)

  private func performInference(context: Context) async throws -> AssistantMessage {
    emit(.streamBegan)
    inflight = []

    defer {
      inflight = nil
      emit(.streamEnded)
    }

    let (deltaStream, deltaContinuation) = AsyncStream<B.StreamAction>.makeStream()
    let sink = AgentStreamSink<B.StreamAction> { deltaContinuation.yield($0) }

    return try await withThrowingTaskGroup(of: AssistantMessage?.self) { group in
      group.addTask { [behavior] in
        defer { deltaContinuation.finish() }
        return try await behavior.infer(context: context, stream: sink)
      }

      // Process deltas on-actor while inference runs off-actor
      for await delta in deltaStream {
        inflight?.append(delta)
        emit(.streamDelta(delta))
      }

      guard let message = try await group.next() ?? nil else {
        throw AgentLoopError.inferenceProducedNoResult
      }
      return message
    }
  }

  // MARK: - Crash Recovery

  /// Find tool calls stuck in `.started` and inject error results.
  private func recoverStaleToolCalls() async throws -> Bool {
    let staleIDs = behavior.staleToolCallIDs(in: state)
    for id in staleIDs {
      try await serialized { [behavior] state in
        try await behavior.recoverStaleToolCall(id: id, state: state)
      }
    }
    return !staleIDs.isEmpty
  }

  // MARK: - Tool Execution

  /// Execute tool calls: mark started (serialized), run in parallel
  /// (NOT serialized), record results (serialized).
  private func executeToolCalls(_ calls: [ToolCall]) async throws {
    // Mark all as started
    for call in calls {
      try await serialized { [behavior] state in
        try await behavior.toolWillExecute(call, state: state)
      }
    }

    // Execute in parallel
    let results: [(ToolCall, Result<B.ToolResult, any Error>)] =
      await withTaskGroup(
        of: (ToolCall, Result<B.ToolResult, any Error>).self
      ) { [behavior] group in
        for call in calls {
          group.addTask {
            do {
              let result = try await behavior.executeToolCall(call)
              return (call, .success(result))
            } catch {
              return (call, .failure(error))
            }
          }
        }
        var outputs: [(ToolCall, Result<B.ToolResult, any Error>)] = []
        for await output in group {
          outputs.append(output)
        }
        return outputs
      }

    // Record results
    for (call, result) in results {
      switch result {
      case .success(let toolResult):
        try await serialized { [behavior] state in
          try await behavior.toolDidExecute(call, result: toolResult, state: state)
        }
      case .failure(let error):
        try await serialized { [behavior] state in
          try await behavior.toolDidFail(call, error: error, state: state)
        }
      }
    }
  }

  // MARK: - Emit

  private func emit(_ event: AgentLoopEvent<B.CommittedAction, B.StreamAction>) {
    for (_, continuation) in observers {
      continuation.yield(event)
    }
  }

  private func emitCommitted(_ actions: [B.CommittedAction]) {
    for action in actions {
      emit(.committed(action))
    }
  }
}

// MARK: - Errors

public enum AgentLoopError: Error {
  case inferenceProducedNoResult
}
