import Foundation
import PiAgent
import PiAI
import WuhuAPI

public actor WuhuService {
  private let store: SQLiteSessionStore
  private let llmRequestLogger: WuhuLLMRequestLogger?
  private let retryPolicy: WuhuLLMRetryPolicy
  private let asyncBashRegistry: WuhuAsyncBashRegistry
  private let instanceID: String
  private let eventHub = WuhuLiveEventHub()
  private var asyncBashRouter: WuhuAsyncBashCompletionRouter?

  private var runtimes: [String: WuhuSessionRuntime] = [:]

  public init(
    store: SQLiteSessionStore,
    llmRequestLogger: WuhuLLMRequestLogger? = nil,
    retryPolicy: WuhuLLMRetryPolicy = .init(),
    asyncBashRegistry: WuhuAsyncBashRegistry = .shared,
  ) {
    self.store = store
    self.llmRequestLogger = llmRequestLogger
    self.retryPolicy = retryPolicy
    self.asyncBashRegistry = asyncBashRegistry
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
    let runtime = WuhuSessionRuntime(sessionID: .init(rawValue: sessionID), store: store, eventHub: eventHub)
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

  public func promptStream(
    sessionID: String,
    input: String,
    user: String? = nil,
    tools: [AnyAgentTool]? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let detached = try await promptDetached(
      sessionID: sessionID,
      input: input,
      user: user,
      tools: tools,
      streamFn: streamFn,
    )

    return try await followSessionStream(
      sessionID: sessionID,
      sinceCursor: detached.userEntry.parentEntryID,
      sinceTime: nil,
      stopAfterIdle: true,
      timeoutSeconds: nil,
    )
  }

  public func promptDetached(
    sessionID: String,
    input: String,
    user: String? = nil,
    tools: [AnyAgentTool]? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) async throws -> WuhuPromptDetachedResponse {
    await ensureAsyncBashRouter()
    let session = try await store.getSession(id: sessionID)

    let resolvedTools = tools ?? WuhuTools.codingAgentTools(
      cwd: session.cwd,
      asyncBash: .init(registry: asyncBashRegistry, sessionID: sessionID, ownerID: instanceID),
    )

    let loggedStreamFn = llmRequestLogger?.makeLoggedStreamFn(base: streamFn, sessionID: sessionID, purpose: .agent) ?? streamFn

    let runtime = runtime(for: sessionID)
    await runtime.setContextCwd(session.cwd)
    await runtime.setTools(resolvedTools)
    await runtime.setStreamFn(loggedStreamFn)

    let userEntry = try await runtime.enqueueFollowUp(input: input, user: user)
    return .init(userEntry: userEntry)
  }

  public func inProcessExecutionInfo(sessionID: String) async -> WuhuInProcessExecutionInfo {
    if let runtime = runtimes[sessionID] {
      return await runtime.inProcessExecutionInfo()
    }
    return .init(activePromptCount: 0)
  }

  public func stopSession(sessionID: String, user: String? = nil) async throws -> WuhuStopSessionResponse {
    if let runtime = runtimes[sessionID] {
      await runtime.stop()
      runtimes[sessionID] = nil
    }

    _ = try await store.getSession(id: sessionID)

    var transcript = try await store.getEntries(sessionID: sessionID)
    let inferred = WuhuSessionExecutionInference.infer(from: transcript)
    guard inferred.state == .executing else {
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
    await eventHub.publish(sessionID: sessionID, event: .entryAppended(stopEntry))
    await eventHub.publish(sessionID: sessionID, event: .idle)

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
    let initiallyIdle: Bool = if let runtime = runtimes[sessionID] { await runtime.isIdle() } else { true }

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
