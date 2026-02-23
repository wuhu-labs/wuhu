import Foundation
import PiAI
import WuhuAPI

public actor WuhuService {
  private let store: SQLiteSessionStore
  private let llmRequestLogger: WuhuLLMRequestLogger?
  private let retryPolicy: WuhuLLMRetryPolicy
  private let asyncBashRegistry: WuhuAsyncBashRegistry
  private let remoteToolsProvider: (@Sendable (_ sessionID: String, _ runnerName: String) async throws -> [AnyAgentTool])?
  private let baseStreamFn: StreamFn
  private let instanceID: String
  private let eventHub = WuhuLiveEventHub()
  private let subscriptionHub = WuhuSessionSubscriptionHub()
  private var asyncBashRouter: WuhuAsyncBashCompletionRouter?

  private var runtimes: [String: WuhuSessionRuntime] = [:]

  public init(
    store: SQLiteSessionStore,
    llmRequestLogger: WuhuLLMRequestLogger? = nil,
    retryPolicy: WuhuLLMRetryPolicy = .init(),
    asyncBashRegistry: WuhuAsyncBashRegistry = .shared,
    remoteToolsProvider: (@Sendable (_ sessionID: String, _ runnerName: String) async throws -> [AnyAgentTool])? = nil,
    baseStreamFn: @escaping StreamFn = PiAI.streamSimple,
  ) {
    self.store = store
    self.llmRequestLogger = llmRequestLogger
    self.retryPolicy = retryPolicy
    self.asyncBashRegistry = asyncBashRegistry
    self.remoteToolsProvider = remoteToolsProvider
    self.baseStreamFn = baseStreamFn
    instanceID = UUID().uuidString.lowercased()
  }

  deinit {
    if let router = asyncBashRouter {
      Task { await router.stop() }
    }
  }

  public func startAgentLoopManager() async {
    // Backwards-compatible entrypoint: keep background listeners alive even as execution
    // is delegated to per-session actors.
    await ensureAsyncBashRouter()
  }

  private func ensureAsyncBashRouter() async {
    guard asyncBashRouter == nil else { return }
    let router = WuhuAsyncBashCompletionRouter(
      registry: asyncBashRegistry,
      instanceID: instanceID,
      enqueueSystemJSON: { [weak self] sessionID, jsonText, timestamp in
        guard let self else { return }
        try? await enqueueSystemJSON(sessionID: sessionID, jsonText: jsonText, timestamp: timestamp)
      },
    )
    asyncBashRouter = router
    await router.start()
  }

  private func runtime(for sessionID: String) -> WuhuSessionRuntime {
    if let existing = runtimes[sessionID] { return existing }
    let runtime = WuhuSessionRuntime(
      sessionID: .init(rawValue: sessionID),
      store: store,
      eventHub: eventHub,
      subscriptionHub: subscriptionHub,
    )
    runtimes[sessionID] = runtime
    return runtime
  }

  private func enqueueSystemJSON(sessionID: String, jsonText: String, timestamp: Date) async throws {
    let input = SystemUrgentInput(source: .asyncBashCallback, content: .text(jsonText))
    try await runtime(for: sessionID).enqueueSystem(input: input, enqueuedAt: timestamp)
  }

  public func setSessionModel(sessionID: String, request: WuhuSetSessionModelRequest) async throws -> WuhuSetSessionModelResponse {
    _ = try await store.getSession(id: sessionID)

    let effectiveModel: String = {
      let trimmed = (request.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
      return WuhuModelCatalog.defaultModelID(for: request.provider)
    }()

    let selection = WuhuSessionSettings(
      provider: request.provider,
      model: effectiveModel,
      reasoningEffort: request.reasoningEffort,
    )

    let applied = try await runtime(for: sessionID).setModelSelection(selection)
    let session = try await store.getSession(id: sessionID)
    return .init(session: session, selection: selection, applied: applied)
  }

  public func createSession(
    sessionID: String,
    provider: WuhuProvider,
    model: String,
    reasoningEffort: ReasoningEffort? = nil,
    systemPrompt: String,
    environmentID: String?,
    environment: WuhuEnvironment,
    runnerName: String? = nil,
    parentSessionID: String? = nil,
  ) async throws -> WuhuSession {
    try await store.createSession(
      sessionID: sessionID,
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
      systemPrompt: systemPrompt,
      environmentID: environmentID,
      environment: environment,
      runnerName: runnerName,
      parentSessionID: parentSessionID,
    )
  }

  public func listSessions(limit: Int? = nil) async throws -> [WuhuSession] {
    try await store.listSessions(limit: limit)
  }

  public func getSession(id: String) async throws -> WuhuSession {
    try await store.getSession(id: id)
  }

  public func getTranscript(sessionID: String) async throws -> [WuhuSessionEntry] {
    try await store.getEntries(sessionID: sessionID)
  }

  public func getTranscript(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
  ) async throws -> [WuhuSessionEntry] {
    try await store.getEntries(sessionID: sessionID, sinceCursor: sinceCursor, sinceTime: sinceTime)
  }

  public func inProcessExecutionInfo(sessionID: String) async -> WuhuInProcessExecutionInfo {
    if let runtime = runtimes[sessionID] {
      return await runtime.inProcessExecutionInfo()
    }
    return .init(activePromptCount: 0)
  }

  public func stopSession(sessionID: String, user: String? = nil) async throws -> WuhuStopSessionResponse {
    let hadRuntime = runtimes[sessionID] != nil
    if let runtime = runtimes[sessionID] {
      await runtime.stop()
      runtimes[sessionID] = nil
    }

    _ = try await store.getSession(id: sessionID)

    var transcript = try await store.getEntries(sessionID: sessionID)
    let inferred = WuhuSessionExecutionInference.infer(from: transcript)

    let shouldAppendStopMarker = hadRuntime || inferred.state == .executing
    guard shouldAppendStopMarker else {
      return .init(repairedEntries: [], stopEntry: nil)
    }

    let toolRepair = try await WuhuToolRepairer.repairMissingToolResultsIfNeeded(
      sessionID: sessionID,
      transcript: transcript,
      mode: .stopped,
      store: store,
      eventHub: eventHub,
    )
    transcript = toolRepair.transcript

    for toolCallId in inferred.pendingToolCallIds.sorted() {
      _ = try await store.setToolCallStatus(sessionID: .init(rawValue: sessionID), id: toolCallId, status: .errored)
    }

    let stoppedBy = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var details: [String: JSONValue] = ["wuhu_event": .string("execution_stopped")]
    if !stoppedBy.isEmpty {
      details["user"] = .string(stoppedBy)
    }

    let stopMessage = WuhuPersistedMessage.customMessage(.init(
      customType: WuhuCustomMessageTypes.executionStopped,
      content: [.text(text: "Execution stopped", signature: nil)],
      details: .object(details),
      display: true,
      timestamp: Date(),
    ))
    let stopEntry = try await store.appendEntry(sessionID: sessionID, payload: .message(stopMessage))
    try await store.setSessionExecutionStatus(sessionID: .init(rawValue: sessionID), status: .stopped)

    await eventHub.publish(sessionID: sessionID, event: .entryAppended(stopEntry))
    await eventHub.publish(sessionID: sessionID, event: .idle)

    await subscriptionHub.publish(
      sessionID: sessionID,
      event: .transcriptAppended([stopEntry]),
    )
    if let status = try? await store.loadStatusSnapshot(sessionID: .init(rawValue: sessionID)) {
      await subscriptionHub.publish(sessionID: sessionID, event: .statusUpdated(status))
    }

    return .init(repairedEntries: toolRepair.repairEntries, stopEntry: stopEntry)
  }

  public func followSessionStream(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
    stopAfterIdle: Bool,
    timeoutSeconds: Double?,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let live = await eventHub.subscribe(sessionID: sessionID)
    let initial = try await store.getEntries(sessionID: sessionID, sinceCursor: sinceCursor, sinceTime: sinceTime)
    let lastInitialCursor = initial.last?.id ?? sinceCursor ?? 0
    let status = try? await store.loadStatusSnapshot(sessionID: .init(rawValue: sessionID))
    let initiallyIdle: Bool = if let runtime = runtimes[sessionID] {
      if status?.status == .running {
        false
      } else {
        await runtime.isIdle()
      }
    } else {
      true
    }

    return AsyncThrowingStream(WuhuSessionStreamEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let forwardTask = Task {
        do {
          for entry in initial {
            continuation.yield(.entryAppended(entry))
          }

          if stopAfterIdle, initiallyIdle {
            continuation.yield(.idle)
            continuation.yield(.done)
            continuation.finish()
            return
          }

          for await event in live {
            switch event {
            case let .entryAppended(entry):
              if entry.id <= lastInitialCursor { continue }
              continuation.yield(event)
            case .assistantTextDelta, .idle:
              continuation.yield(event)
              if stopAfterIdle, case .idle = event {
                continuation.yield(.done)
                continuation.finish()
                return
              }
            case .done:
              // Should not be published to live subscribers.
              break
            }
          }

          continuation.finish()
        }
      }

      let timeoutTask: Task<Void, Never>? = timeoutSeconds.flatMap { seconds in
        Task {
          let ns = UInt64(max(0, seconds) * 1_000_000_000)
          try? await Task.sleep(nanoseconds: ns)
          continuation.yield(.done)
          continuation.finish()
        }
      }

      continuation.onTermination = { _ in
        forwardTask.cancel()
        timeoutTask?.cancel()
      }
    }
  }

  // Async bash completion handling lives in `WuhuAsyncBashCompletionRouter`.
}

// MARK: - New session contracts

extension WuhuService: SessionCommanding, SessionSubscribing {
  public func enqueue(sessionID: SessionID, message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    await ensureAsyncBashRouter()
    let session = try await store.getSession(id: sessionID.rawValue)

    let resolvedTools: [AnyAgentTool] = if let runnerName = session.runnerName, !runnerName.isEmpty {
      if let remoteToolsProvider {
        try await remoteToolsProvider(sessionID.rawValue, runnerName)
      } else {
        // Remote sessions require a server-provided tool executor; fail loudly.
        throw PiAIError.unsupported("Session '\(sessionID.rawValue)' uses runner '\(runnerName)', but no remoteToolsProvider is configured")
      }
    } else {
      WuhuTools.codingAgentTools(
        cwd: session.cwd,
        asyncBash: .init(registry: asyncBashRegistry, sessionID: sessionID.rawValue, ownerID: instanceID),
      )
    }

    let streamFn = llmRequestLogger?.makeLoggedStreamFn(base: baseStreamFn, sessionID: sessionID.rawValue, purpose: .agent) ?? baseStreamFn

    let runtime = runtime(for: sessionID.rawValue)
    await runtime.setContextCwd(session.cwd)
    await runtime.setTools(resolvedTools)
    await runtime.setStreamFn(streamFn)
    await runtime.ensureStarted()
    return try await runtime.enqueue(message: message, lane: lane)
  }

  public func cancel(sessionID: SessionID, id: QueueItemID, lane: UserQueueLane) async throws {
    _ = try await store.getSession(id: sessionID.rawValue)
    let runtime = runtime(for: sessionID.rawValue)
    await runtime.ensureStarted()
    try await runtime.cancel(id: id, lane: lane)
  }

  public func subscribe(sessionID: SessionID, since request: SessionSubscriptionRequest) async throws -> SessionSubscription {
    _ = try await store.getSession(id: sessionID.rawValue)

    // Subscribe first, then backfill (bufferingNewest in the hub bridges the gap).
    let live = await subscriptionHub.subscribe(sessionID: sessionID.rawValue)

    // Ensure the session actor is running so future events will be published.
    let runtime = runtime(for: sessionID.rawValue)
    await runtime.ensureStarted()

    let initial = try await loadInitialState(sessionID: sessionID, request: request)

    let lastTranscriptID0: Int64 = {
      let fromRequest = Int64(request.transcriptSince?.rawValue ?? "") ?? 0
      let fromInitial = initial.transcript.last?.id ?? 0
      return max(fromRequest, fromInitial)
    }()

    let lastSystemCursor0 = Int64(initial.systemUrgent.cursor.rawValue) ?? 0
    let lastSteerCursor0 = Int64(initial.steer.cursor.rawValue) ?? 0
    let lastFollowUpCursor0 = Int64(initial.followUp.cursor.rawValue) ?? 0

    let events = AsyncThrowingStream(SessionEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let forwardTask = Task {
        var lastTranscriptID = lastTranscriptID0
        var lastSystemCursor = lastSystemCursor0
        var lastSteerCursor = lastSteerCursor0
        var lastFollowUpCursor = lastFollowUpCursor0

        for await event in live {
          if Task.isCancelled { break }

          switch event {
          case let .transcriptAppended(entries):
            let filtered = entries.filter { $0.id > lastTranscriptID }
            guard !filtered.isEmpty else { continue }
            lastTranscriptID = max(lastTranscriptID, filtered.map(\.id).max() ?? lastTranscriptID)
            continuation.yield(.transcriptAppended(filtered))

          case let .systemUrgentQueue(cursor, entries):
            let cursorVal = Int64(cursor.rawValue) ?? 0
            if cursorVal <= lastSystemCursor { continue }
            lastSystemCursor = cursorVal
            continuation.yield(.systemUrgentQueue(cursor: cursor, entries: entries))

          case let .userQueue(cursor, entries):
            guard let lane = entries.first?.lane else {
              continuation.yield(.userQueue(cursor: cursor, entries: entries))
              continue
            }
            let cursorVal = Int64(cursor.rawValue) ?? 0
            switch lane {
            case .steer:
              if cursorVal <= lastSteerCursor { continue }
              lastSteerCursor = cursorVal
              continuation.yield(.userQueue(cursor: cursor, entries: entries))
            case .followUp:
              if cursorVal <= lastFollowUpCursor { continue }
              lastFollowUpCursor = cursorVal
              continuation.yield(.userQueue(cursor: cursor, entries: entries))
            }

          case let .settingsUpdated(settings):
            continuation.yield(.settingsUpdated(settings))

          case let .statusUpdated(status):
            continuation.yield(.statusUpdated(status))
          }
        }
        continuation.finish()
      }

      continuation.onTermination = { _ in
        forwardTask.cancel()
      }
    }

    return .init(initial: initial, events: events)
  }

  private func loadInitialState(sessionID: SessionID, request: SessionSubscriptionRequest) async throws -> SessionInitialState {
    let settings = try await store.loadSettingsSnapshot(sessionID: sessionID)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)

    let sinceCursor = Int64(request.transcriptSince?.rawValue ?? "")
    let entries = try await store.getEntries(sessionID: sessionID.rawValue, sinceCursor: sinceCursor, sinceTime: nil)
    let transcript = entries

    let systemUrgent = try await store.loadSystemQueueBackfill(sessionID: sessionID, since: request.systemSince)
    let steer = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: .steer, since: request.steerSince)
    let followUp = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: .followUp, since: request.followUpSince)

    return .init(
      settings: settings,
      status: status,
      transcript: transcript,
      systemUrgent: systemUrgent,
      steer: steer,
      followUp: followUp,
    )
  }
}
