import Foundation
import PiAgent
import PiAI
import WuhuAPI

actor WuhuSessionRuntime {
  private let sessionID: SessionID
  private let store: SQLiteSessionStore
  private let eventHub: WuhuLiveEventHub
  private let subscriptionHub: WuhuSessionSubscriptionHub
  private let runtimeConfig: WuhuSessionRuntimeConfig

  private var publishedSystemCursor: QueueCursor = .init(rawValue: "0")
  private var publishedSteerCursor: QueueCursor = .init(rawValue: "0")
  private var publishedFollowUpCursor: QueueCursor = .init(rawValue: "0")

  private let behavior: WuhuSessionBehavior
  private let loop: AgentLoop<WuhuSessionBehavior>

  private var startTask: Task<Void, Never>?
  private var observeTask: Task<Void, Never>?

  private var streaming: Bool = false
  private var observedState: WuhuSessionLoopState = .empty
  private var observationReady: Bool = false

  init(sessionID: SessionID, store: SQLiteSessionStore, eventHub: WuhuLiveEventHub, subscriptionHub: WuhuSessionSubscriptionHub) {
    self.sessionID = sessionID
    self.store = store
    self.eventHub = eventHub
    self.subscriptionHub = subscriptionHub
    runtimeConfig = WuhuSessionRuntimeConfig()
    behavior = WuhuSessionBehavior(sessionID: sessionID, store: store, runtimeConfig: runtimeConfig)
    loop = AgentLoop(behavior: behavior)
  }

  func ensureStarted() async {
    if startTask != nil { return }

    startTask = Task { [loop] in
      do {
        try await loop.start()
      } catch {
        // Best-effort: loop runs for process lifetime; ignore failures here.
      }
    }

    observeTask = Task { [weak self] in
      guard let self else { return }
      let observation = await loop.observe()
      await setInitialObservationState(observation)
      for await event in observation.events {
        await handleLoopEvent(event)
      }
    }

    while !observationReady {
      await Task.yield()
    }
  }

  func setTools(_ tools: [AnyAgentTool]) async {
    await runtimeConfig.setTools(tools)
  }

  func setStreamFn(_ streamFn: @escaping StreamFn) async {
    await runtimeConfig.setStreamFn(streamFn)
  }

  func setContextCwd(_ cwd: String) async {
    await runtimeConfig.setContextActor(WuhuAgentsContextActor(cwd: cwd))
  }

  func isIdle() -> Bool {
    // Fast-path: don't block callers on observation if they only need a best-effort hint.
    !streaming && !behavior.hasWork(state: observedState)
  }

  func inProcessExecutionInfo() -> WuhuInProcessExecutionInfo {
    let queued = observedState.followUp.pending.count
    let active = streaming ? 1 : 0
    return .init(activePromptCount: active + queued)
  }

  func enqueue(message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    try await loop.send(.enqueueUser(id: id, message: message, lane: lane))
    return id
  }

  func cancel(id: QueueItemID, lane: UserQueueLane) async throws {
    await ensureStarted()
    try await loop.send(.cancelUser(id: id, lane: lane))
  }

  func enqueueFollowUp(input: String, user: String?) async throws -> WuhuSessionEntry {
    await ensureStarted()
    let author: Author = {
      let trimmed = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return .unknown }
      return .participant(.init(rawValue: trimmed), kind: .human)
    }()
    let message = QueuedUserMessage(author: author, content: .text(input))

    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    try await loop.send(.enqueueUser(id: id, message: message, lane: .followUp))
    return try await waitForMaterialization(queueItemID: id, lane: .followUp)
  }

  func enqueueSystem(input: SystemUrgentInput, enqueuedAt: Date = Date()) async throws {
    await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    try await loop.send(.enqueueSystem(id: id, input: input, enqueuedAt: enqueuedAt))
  }

  func setModelSelection(_ selection: WuhuSessionSettings) async throws -> Bool {
    await ensureStarted()

    if !streaming, !behavior.hasWork(state: observedState) {
      try await loop.send(.applyModelSelection(selection))
      // Observe if the session updates quickly; otherwise treat as deferred.
      let updated = try await store.getSession(id: sessionID.rawValue)
      return updated.model == selection.model && updated.provider == selection.provider
    }

    try await loop.send(.setPendingModelSelection(selection))
    return false
  }

  func applyPendingModelIfPossible() async throws {
    await ensureStarted()
    if streaming || behavior.hasWork(state: observedState) { return }
    try await loop.send(.applyPendingModelIfPossible)
  }

  func stop() async {
    let start = startTask
    let observe = observeTask

    start?.cancel()
    observe?.cancel()

    _ = await start?.result
    _ = await observe?.result

    startTask = nil
    observeTask = nil
    observationReady = false
    streaming = false
    observedState = .empty

    publishedSystemCursor = .init(rawValue: "0")
    publishedSteerCursor = .init(rawValue: "0")
    publishedFollowUpCursor = .init(rawValue: "0")
  }

  // MARK: - Observation handling

  private func setInitialObservationState(_ observation: AgentLoopObservation<WuhuSessionBehavior>) async {
    observedState = observation.state
    streaming = observation.inflight != nil

    publishedSystemCursor = observation.state.systemUrgent.cursor
    publishedSteerCursor = observation.state.steer.cursor
    publishedFollowUpCursor = observation.state.followUp.cursor

    observationReady = true
  }

  private func handleLoopEvent(_ event: AgentLoopEvent<WuhuSessionCommittedAction, WuhuSessionStreamAction>) async {
    switch event {
    case let .committed(action):
      behavior.apply(action, to: &observedState)
      switch action {
      case let .entryAppended(entry):
        await eventHub.publish(sessionID: sessionID.rawValue, event: .entryAppended(entry))
        await subscriptionHub.publish(
          sessionID: sessionID.rawValue,
          event: .transcriptAppended([entry]),
        )

      case .sessionUpdated:
        break

      case .toolCallStatusUpdated:
        break

      case .systemQueueUpdated:
        let delta = try? await store.loadSystemQueueJournal(sessionID: sessionID, since: publishedSystemCursor)
        if let delta {
          publishedSystemCursor = delta.cursor
          if !delta.entries.isEmpty {
            await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .systemUrgentQueue(cursor: delta.cursor, entries: delta.entries))
          }
        }

      case let .userQueueUpdated(lane, _):
        switch lane {
        case .steer:
          let delta = try? await store.loadUserQueueJournal(sessionID: sessionID, lane: lane, since: publishedSteerCursor)
          if let delta {
            publishedSteerCursor = delta.cursor
            if !delta.entries.isEmpty {
              await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .userQueue(cursor: delta.cursor, entries: delta.entries))
            }
          }
        case .followUp:
          let delta = try? await store.loadUserQueueJournal(sessionID: sessionID, lane: lane, since: publishedFollowUpCursor)
          if let delta {
            publishedFollowUpCursor = delta.cursor
            if !delta.entries.isEmpty {
              await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .userQueue(cursor: delta.cursor, entries: delta.entries))
            }
          }
        }

      case let .settingsUpdated(settings):
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .settingsUpdated(settings))

      case let .statusUpdated(status):
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .statusUpdated(status))
      }

      if isIdle() {
        await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
        // Best-effort: apply deferred model changes once idle.
        Task { [weak self] in
          try? await self?.applyPendingModelIfPossible()
        }
      }

    case .streamBegan:
      streaming = true

    case let .streamDelta(delta):
      switch delta {
      case let .assistantTextDelta(text):
        await eventHub.publish(sessionID: sessionID.rawValue, event: .assistantTextDelta(text))
      }

    case .streamEnded:
      streaming = false
      if isIdle() {
        await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
      }
    }
  }

  // MARK: - Waiting helpers

  private func waitForMaterialization(queueItemID: QueueItemID, lane: UserQueueLane) async throws -> WuhuSessionEntry {
    let timeoutNs: UInt64 = 120_000_000_000 // 120s
    let start = DispatchTime.now().uptimeNanoseconds

    while true {
      if let transcriptEntryID = materializedTranscriptEntryID(queueItemID: queueItemID, lane: lane) {
        if let entry = observedState.entries.first(where: { transcriptEntryID.rawValue == "\($0.id)" }) {
          return entry
        }
      }

      if DispatchTime.now().uptimeNanoseconds - start > timeoutNs {
        throw PiAIError.unsupported("Timed out waiting for prompt materialization")
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func materializedTranscriptEntryID(queueItemID: QueueItemID, lane: UserQueueLane) -> TranscriptEntryID? {
    let journal = switch lane {
    case .steer:
      observedState.steer.journal
    case .followUp:
      observedState.followUp.journal
    }

    for entry in journal.reversed() {
      if case let .materialized(lane: _, id: id, transcriptEntryID: transcriptEntryID, at: _) = entry,
         id == queueItemID
      {
        return transcriptEntryID
      }
    }
    return nil
  }
}
