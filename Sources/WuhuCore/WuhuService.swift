import Foundation
import PiAgent
import PiAI
import WuhuAPI

public actor WuhuService {
  private let store: any SessionStore
  private let llmRequestLogger: WuhuLLMRequestLogger?
  private let retryPolicy: WuhuLLMRetryPolicy
  private let asyncBashRegistry: WuhuAsyncBashRegistry
  private let instanceID: String
  private var asyncBashCompletionTask: Task<Void, Never>?
  private var sessionContextActors: [String: WuhuAgentsContextActor] = [:]
  private var sessionContextActorLastAccess: [String: Date] = [:]
  private let maxSessionContextActors = 64

  private var liveSubscribers: [String: [UUID: AsyncStream<WuhuSessionStreamEvent>.Continuation]] = [:]
  private var activePromptCount: [String: Int] = [:]
  private struct ActiveExecution: Sendable {
    var agent: PiAgent.Agent
    var cancel: @Sendable () -> Void
  }

  private var activeExecutions: [String: [UUID: ActiveExecution]] = [:]

  private var pendingModelSelection: [String: WuhuSessionSettings] = [:]
  private var lastAssistantMessageHadToolCalls: [String: Bool] = [:]

  private enum AgentLoopManagerCommand: Sendable {
    case startSession(sessionID: String, stream: AsyncStream<SessionLoopCommand>)
    case shutdown
  }

  private enum SessionLoopCommand: Sendable {
    case execute(ExecutionWorkItem)
  }

  private struct ExecutionWorkItem: Sendable {
    var sessionID: String
    var token: UUID
    var agent: PiAgent.Agent
    var renderedInput: String
  }

  private var agentLoopManagerTask: Task<Void, Never>?
  private var agentLoopManagerContinuation: AsyncStream<AgentLoopManagerCommand>.Continuation?
  private var sessionLoopContinuations: [String: AsyncStream<SessionLoopCommand>.Continuation] = [:]

  public init(
    store: any SessionStore,
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
    agentLoopManagerTask?.cancel()
    agentLoopManagerContinuation?.finish()
    for (_, continuation) in sessionLoopContinuations {
      continuation.finish()
    }
    asyncBashCompletionTask?.cancel()
  }

  public func startAgentLoopManager() {
    guard agentLoopManagerTask == nil else { return }
    ensureAsyncBashCompletionListener()

    var capturedContinuation: AsyncStream<AgentLoopManagerCommand>.Continuation?
    let commands = AsyncStream(AgentLoopManagerCommand.self, bufferingPolicy: .unbounded) { continuation in
      capturedContinuation = continuation
    }
    agentLoopManagerContinuation = capturedContinuation

    agentLoopManagerTask = Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        var startedSessions: Set<String> = []
        var shouldExit = false

        for await command in commands {
          if Task.isCancelled { break }
          if self == nil { break }

          switch command {
          case let .startSession(sessionID, stream):
            guard !startedSessions.contains(sessionID) else { continue }
            startedSessions.insert(sessionID)
            group.addTask { [weak self] in
              for await sessionCommand in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                switch sessionCommand {
                case let .execute(item):
                  await executeWorkItem(item)
                }
              }
            }
          case .shutdown:
            shouldExit = true
          }

          if shouldExit { break }
        }

        group.cancelAll()
      }
    }
  }

  public func shutdownAgentLoopManager() {
    agentLoopManagerContinuation?.yield(.shutdown)
    agentLoopManagerContinuation?.finish()
    agentLoopManagerContinuation = nil

    for (_, continuation) in sessionLoopContinuations {
      continuation.finish()
    }
    sessionLoopContinuations = [:]

    agentLoopManagerTask?.cancel()
    agentLoopManagerTask = nil
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

    let canApplyNow = isIdle(sessionID: sessionID) && (lastAssistantMessageHadToolCalls[sessionID] != true)
    if canApplyNow {
      _ = try await applyModelSelection(sessionID: sessionID, selection: selection)
      let session = try await store.getSession(id: sessionID)
      pendingModelSelection[sessionID] = nil
      return .init(session: session, selection: selection, applied: true)
    }

    pendingModelSelection[sessionID] = selection
    let session = try await store.getSession(id: sessionID)
    return .init(session: session, selection: selection, applied: false)
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
    startAgentLoopManager()
    ensureAsyncBashCompletionListener()
    guard isIdle(sessionID: sessionID) else {
      throw PiAIError.unsupported("Session is already executing")
    }

    let effectiveUser = Self.normalizeUser(user)
    let session = try await store.getSession(id: sessionID)
    var transcript = try await store.getEntries(sessionID: sessionID)

    let toolRepair = try await repairMissingToolResultsIfNeeded(sessionID: sessionID, transcript: transcript, mode: .lost)
    transcript = toolRepair.transcript

    _ = try await maybeAppendGroupChatReminderIfNeeded(
      sessionID: sessionID,
      transcript: transcript,
      promptingUser: effectiveUser,
    )
    transcript = try await store.getEntries(sessionID: sessionID)

    let header = try Self.extractHeader(from: transcript, sessionID: sessionID)
    let settingsOverride = Self.extractLatestSessionSettings(from: transcript)
    let model = Model(id: session.model, provider: session.provider.piProvider)

    let loggedAgentStreamFn = llmRequestLogger?.makeLoggedStreamFn(base: streamFn, sessionID: sessionID, purpose: .agent) ?? streamFn
    let loggedCompactionStreamFn = llmRequestLogger?.makeLoggedStreamFn(base: streamFn, sessionID: sessionID, purpose: .compaction) ?? streamFn
    let agentStreamFn = makeRetryingStreamFn(base: loggedAgentStreamFn, sessionID: sessionID, purpose: .agent)
    let compactionStreamFn = makeRetryingStreamFn(base: loggedCompactionStreamFn, sessionID: sessionID, purpose: .compaction)

    let resolvedTools = tools ?? WuhuTools.codingAgentTools(
      cwd: session.cwd,
      asyncBash: .init(registry: asyncBashRegistry, sessionID: sessionID, ownerID: instanceID),
    )

    var effectiveSystemPrompt = header.systemPrompt
    let injectedContext = await sessionContextActor(for: sessionID, cwd: session.cwd).contextSection()
    if !injectedContext.isEmpty {
      effectiveSystemPrompt += injectedContext
    }
    effectiveSystemPrompt += "\n\nWorking directory: \(session.cwd)\nAll relative paths are resolved from this directory."

    var requestOptions = RequestOptions()
    let sessionEffort = settingsOverride != nil ? settingsOverride?.reasoningEffort : Self.extractReasoningEffort(from: header)
    if let effort = sessionEffort {
      requestOptions.reasoningEffort = effort
    } else if model.provider == .openai || model.provider == .openaiCodex,
              model.id.contains("gpt-5") || model.id.contains("codex")
    {
      requestOptions.reasoningEffort = .low
    }

    let compactionSettings = WuhuCompactionSettings.load(model: model)
    let groupChatActive = WuhuGroupChat.reminderEntryIndex(in: transcript) != nil
    let renderedInput = groupChatActive ? WuhuGroupChat.renderPromptInput(user: effectiveUser, input: input) : input
    transcript = try await maybeAutoCompact(
      sessionID: sessionID,
      transcript: transcript,
      model: model,
      requestOptions: requestOptions,
      compactionSettings: compactionSettings,
      input: renderedInput,
      streamFn: compactionStreamFn,
    )

    let messages = Self.extractContextMessages(from: transcript)

    let agent = PiAgent.Agent(opts: .init(
      initialState: .init(
        systemPrompt: effectiveSystemPrompt,
        model: model,
        tools: resolvedTools,
        messages: messages,
      ),
      requestOptions: requestOptions,
      streamFn: agentStreamFn,
    ))

    let executionToken = UUID()
    beginPrompt(sessionID: sessionID, token: executionToken, agent: agent)
    let userEntry = try await store.appendEntry(sessionID: sessionID, payload: .message(.user(.init(
      user: effectiveUser,
      content: [.text(text: input, signature: nil)],
      timestamp: Date(),
    ))))
    publishLiveEvent(sessionID: sessionID, event: .entryAppended(userEntry))

    ensureSessionLoop(sessionID: sessionID)
    sessionLoopContinuations[sessionID]?.yield(.execute(.init(
      sessionID: sessionID,
      token: executionToken,
      agent: agent,
      renderedInput: renderedInput,
    )))

    return WuhuPromptDetachedResponse(userEntry: userEntry)
  }

  public func inProcessExecutionInfo(sessionID: String) -> WuhuInProcessExecutionInfo {
    let count = activeExecutions[sessionID]?.count ?? 0
    return .init(activePromptCount: count)
  }

  public func stopSession(sessionID: String, user: String? = nil) async throws -> WuhuStopSessionResponse {
    _ = try await store.getSession(id: sessionID)

    let transcript = try await store.getEntries(sessionID: sessionID)
    let inferred = WuhuSessionExecutionInference.infer(from: transcript)
    let inProcessCount = activeExecutions[sessionID]?.count ?? 0

    guard inferred.state == .executing || inProcessCount > 0 else {
      return .init(repairedEntries: [], stopEntry: nil)
    }

    let runningTokens: [UUID] = activeExecutions[sessionID].map { Array($0.keys) } ?? []
    for token in runningTokens {
      activeExecutions[sessionID]?[token]?.cancel()
      removeActiveExecution(sessionID: sessionID, token: token)
    }

    var updatedTranscript = try await store.getEntries(sessionID: sessionID)
    let toolRepair = try await repairMissingToolResultsIfNeeded(sessionID: sessionID, transcript: updatedTranscript, mode: .stopped)
    updatedTranscript = toolRepair.transcript

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
    publishLiveEvent(sessionID: sessionID, event: .entryAppended(stopEntry))

    for _ in runningTokens {
      endPrompt(sessionID: sessionID)
    }
    await applyPendingModelSelectionIfPossible(sessionID: sessionID)

    return .init(repairedEntries: toolRepair.repairEntries, stopEntry: stopEntry)
  }

  public func followSessionStream(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
    stopAfterIdle: Bool,
    timeoutSeconds: Double?,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let live = subscribeLiveEvents(sessionID: sessionID)
    let initial = try await store.getEntries(sessionID: sessionID, sinceCursor: sinceCursor, sinceTime: sinceTime)
    let lastInitialCursor = initial.last?.id ?? sinceCursor ?? 0
    let initiallyIdle = isIdle(sessionID: sessionID)

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

  private func maybeAutoCompact(
    sessionID: String,
    transcript: [WuhuSessionEntry],
    model: Model,
    requestOptions: RequestOptions,
    compactionSettings: WuhuCompactionSettings,
    input: String,
    streamFn: @escaping StreamFn,
  ) async throws -> [WuhuSessionEntry] {
    var current = transcript

    for _ in 0 ..< 3 {
      let contextMessages = Self.extractContextMessages(from: current)
      let prospective = contextMessages + [.user(input)]
      let estimate = WuhuCompactionEngine.estimateContextTokens(messages: prospective)

      if !WuhuCompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: compactionSettings) {
        break
      }

      guard let preparation = WuhuCompactionEngine.prepareCompaction(transcript: current, settings: compactionSettings) else {
        break
      }

      let summary = try await WuhuCompactionEngine.generateSummary(
        preparation: preparation,
        model: model,
        settings: compactionSettings,
        requestOptions: requestOptions,
        streamFn: streamFn,
      )

      let entry = try await store.appendEntry(sessionID: sessionID, payload: .compaction(.init(
        summary: summary,
        tokensBefore: preparation.tokensBefore,
        firstKeptEntryID: preparation.firstKeptEntryID,
      )))
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))

      current = try await store.getEntries(sessionID: sessionID)
    }

    return current
  }

  private func handleAgentEvent(
    _ event: AgentEvent,
    sessionID: String,
    token: UUID,
    continuation: AsyncThrowingStream<WuhuSessionStreamEvent, any Error>.Continuation?,
  ) async throws {
    guard activeExecutions[sessionID]?[token] != nil else {
      return
    }

    switch event {
    case let .toolExecutionStart(toolCallId, toolName, args):
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: toolCallId,
        toolName: toolName,
        arguments: args,
      )))
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
      continuation?.yield(.entryAppended(entry))

    case let .toolExecutionEnd(toolCallId, toolName, result, isError):
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .toolExecution(.init(
        phase: .end,
        toolCallId: toolCallId,
        toolName: toolName,
        arguments: .null,
        result: .object([
          "content": .array(result.content.map(Self.contentBlockToJSON)),
          "details": result.details,
        ]),
        isError: isError,
      )))
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
      continuation?.yield(.entryAppended(entry))

    case let .messageUpdate(message, assistantEvent):
      if case .assistant = message, case let .textDelta(delta, _) = assistantEvent {
        publishLiveEvent(sessionID: sessionID, event: .assistantTextDelta(delta))
        continuation?.yield(.assistantTextDelta(delta))
      }

    case let .messageEnd(message):
      if case .user = message {
        break
      }
      if case let .assistant(a) = message {
        lastAssistantMessageHadToolCalls[sessionID] = a.content.contains { if case .toolCall = $0 { return true }; return false }
      }
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(message)))
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
      continuation?.yield(.entryAppended(entry))

    default:
      break
    }
  }

  private static func extractHeader(from transcript: [WuhuSessionEntry], sessionID: String) throws -> WuhuSessionHeader {
    guard let headerEntry = transcript.first(where: { $0.parentEntryID == nil }) else {
      throw WuhuStoreError.noHeaderEntry(sessionID)
    }
    guard case let .header(header) = headerEntry.payload else {
      throw WuhuStoreError.sessionCorrupt("Header entry \(headerEntry.id) payload is not header")
    }
    return header
  }

  private static func extractReasoningEffort(from header: WuhuSessionHeader) -> ReasoningEffort? {
    guard let metadata = header.metadata.object else { return nil }
    guard let raw = metadata["reasoningEffort"]?.stringValue else { return nil }
    return ReasoningEffort(rawValue: raw)
  }

  private static func extractContextMessages(from transcript: [WuhuSessionEntry]) -> [Message] {
    let headerIndex = transcript.firstIndex(where: { $0.parentEntryID == nil }) ?? 0
    let reminderIndex = WuhuGroupChat.reminderEntryIndex(in: transcript)

    var summary: String?
    var firstKeptEntryID: Int64?

    if let entry = transcript.last(where: { if case .compaction = $0.payload { return true }; return false }),
       case let .compaction(compaction) = entry.payload
    {
      summary = compaction.summary
      firstKeptEntryID = compaction.firstKeptEntryID
    }

    let startIndex: Int = if let firstKeptEntryID {
      transcript.firstIndex(where: { $0.id == firstKeptEntryID }) ?? min(headerIndex + 1, transcript.count)
    } else {
      min(headerIndex + 1, transcript.count)
    }

    var messages: [Message] = []
    if let summary, !summary.isEmpty {
      messages.append(WuhuCompactionEngine.makeSummaryMessage(summary: summary))
    }

    for (idx, entry) in transcript[startIndex...].enumerated() {
      let entryIndex = startIndex + idx
      guard case let .message(m) = entry.payload else { continue }
      guard let pi = WuhuGroupChat.renderForLLM(message: m, entryIndex: entryIndex, reminderIndex: reminderIndex) else { continue }
      messages.append(pi)
    }

    return repairMissingToolResultsInMemory(messages)
  }

  private static func extractLatestSessionSettings(from transcript: [WuhuSessionEntry]) -> WuhuSessionSettings? {
    for entry in transcript.reversed() {
      if case let .sessionSettings(s) = entry.payload {
        return s
      }
    }
    return nil
  }

  private static func normalizeUser(_ user: String?) -> String {
    let trimmed = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? WuhuUserMessage.unknownUser : trimmed
  }

  private static func firstPromptingUser(in transcript: [WuhuSessionEntry]) -> String? {
    for entry in transcript {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .user(u) = m else { continue }
      return u.user
    }
    return nil
  }

  private func maybeAppendGroupChatReminderIfNeeded(
    sessionID: String,
    transcript: [WuhuSessionEntry],
    promptingUser: String,
  ) async throws -> WuhuSessionEntry? {
    if WuhuGroupChat.reminderEntryIndex(in: transcript) != nil {
      return nil
    }

    guard let firstUser = Self.firstPromptingUser(in: transcript) else {
      return nil
    }

    guard firstUser != promptingUser else {
      return nil
    }

    let reminderEntry = try await store.appendEntry(
      sessionID: sessionID,
      payload: .message(WuhuGroupChat.makeReminderMessage(previousUser: firstUser)),
    )
    publishLiveEvent(sessionID: sessionID, event: .entryAppended(reminderEntry))
    return reminderEntry
  }

  private static func contentBlockToJSON(_ block: ContentBlock) -> JSONValue {
    switch block {
    case let .text(t):
      var obj: [String: JSONValue] = ["type": .string("text"), "text": .string(t.text)]
      if let signature = t.signature {
        obj["signature"] = .string(signature)
      }
      return .object(obj)
    case let .toolCall(c):
      return .object([
        "type": .string("tool_call"),
        "id": .string(c.id),
        "name": .string(c.name),
        "arguments": c.arguments,
      ])
    case let .reasoning(r):
      var obj: [String: JSONValue] = [
        "type": .string("reasoning"),
        "id": .string(r.id),
        "summary": .array(r.summary),
      ]
      if let encrypted = r.encryptedContent {
        obj["encrypted_content"] = .string(encrypted)
      }
      return .object(obj)
    }
  }

  private static let lostToolResultText =
    "The result for this tool call has been lost. Retry if needed. The tool call might or might not have taken place; for non-idempotent actions, check the current state before continuing."

  private static let stoppedToolResultText =
    "Execution was stopped before a result for this tool call was recorded. Retry if needed. The tool call might or might not have taken place; for non-idempotent actions, check the current state before continuing."

  private struct ToolRepairResult: Sendable {
    var transcript: [WuhuSessionEntry]
    var repairEntries: [WuhuSessionEntry]
  }

  private enum ToolRepairMode: Sendable {
    case lost
    case stopped
  }

  private func repairMissingToolResultsIfNeeded(
    sessionID: String,
    transcript: [WuhuSessionEntry],
    mode: ToolRepairMode,
  ) async throws -> ToolRepairResult {
    var pendingOrder: [String] = []
    var pendingNames: [String: String] = [:]

    var lastMessage: Message?

    for entry in transcript {
      guard case let .message(m) = entry.payload else { continue }
      guard let pi = m.toPiMessage() else { continue }
      lastMessage = pi
      switch pi {
      case let .assistant(a):
        for block in a.content {
          guard case let .toolCall(call) = block else { continue }
          if pendingNames[call.id] == nil {
            pendingOrder.append(call.id)
          }
          pendingNames[call.id] = call.name
        }
      case let .toolResult(r):
        pendingNames[r.toolCallId] = nil
        pendingOrder.removeAll(where: { $0 == r.toolCallId })
      case .user:
        break
      }
    }

    guard !pendingOrder.isEmpty else {
      return ToolRepairResult(transcript: transcript, repairEntries: [])
    }

    // Only persist a repair when the transcript ends with an assistant tool-call message.
    guard case let .assistant(lastAssistant) = lastMessage else {
      return ToolRepairResult(transcript: transcript, repairEntries: [])
    }
    let lastAssistantToolCallIDs = Set(lastAssistant.content.compactMap { block -> String? in
      if case let .toolCall(call) = block { return call.id }
      return nil
    })
    guard !lastAssistantToolCallIDs.isEmpty,
          pendingOrder.allSatisfy({ lastAssistantToolCallIDs.contains($0) })
    else {
      return ToolRepairResult(transcript: transcript, repairEntries: [])
    }

    var updatedTranscript = transcript
    var repairEntries: [WuhuSessionEntry] = []

    for toolCallId in pendingOrder {
      guard let toolName = pendingNames[toolCallId] else { continue }

      let reason = switch mode {
      case .lost:
        "lost"
      case .stopped:
        "stopped"
      }
      let text: String = switch mode {
      case .lost:
        Self.lostToolResultText
      case .stopped:
        Self.stoppedToolResultText
      }

      let repaired: Message = .toolResult(.init(
        toolCallId: toolCallId,
        toolName: toolName,
        content: [.text(text)],
        details: .object([
          "wuhu_repair": .string("missing_tool_result"),
          "reason": .string(reason),
        ]),
        isError: true,
      ))

      let entry = try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(repaired)))
      updatedTranscript.append(entry)
      repairEntries.append(entry)
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
    }

    return ToolRepairResult(transcript: updatedTranscript, repairEntries: repairEntries)
  }

  private static func repairMissingToolResultsInMemory(_ messages: [Message]) -> [Message] {
    var repaired: [Message] = []
    repaired.reserveCapacity(messages.count)

    var pendingOrder: [String] = []
    var pendingNames: [String: String] = [:]

    func injectMissingToolResults(timestamp: Date) {
      guard !pendingOrder.isEmpty else { return }
      for toolCallId in pendingOrder {
        guard let toolName = pendingNames[toolCallId] else { continue }
        repaired.append(.toolResult(.init(
          toolCallId: toolCallId,
          toolName: toolName,
          content: [.text(Self.lostToolResultText)],
          details: .object([
            "wuhu_repair": .string("missing_tool_result"),
            "reason": .string("lost"),
          ]),
          isError: true,
          timestamp: timestamp,
        )))
      }
      pendingOrder = []
      pendingNames = [:]
    }

    for msg in messages {
      switch msg {
      case let .toolResult(r):
        repaired.append(msg)
        if pendingNames[r.toolCallId] != nil {
          pendingNames[r.toolCallId] = nil
          pendingOrder.removeAll(where: { $0 == r.toolCallId })
        }

      case let .assistant(a):
        if !pendingOrder.isEmpty {
          injectMissingToolResults(timestamp: msg.timestamp)
        }
        repaired.append(msg)
        for block in a.content {
          guard case let .toolCall(call) = block else { continue }
          if pendingNames[call.id] == nil {
            pendingOrder.append(call.id)
          }
          pendingNames[call.id] = call.name
        }

      case .user:
        if !pendingOrder.isEmpty {
          injectMissingToolResults(timestamp: msg.timestamp)
        }
        repaired.append(msg)
      }
    }

    if !pendingOrder.isEmpty {
      injectMissingToolResults(timestamp: messages.last?.timestamp ?? Date())
    }

    return repaired
  }

  private func sessionContextActor(for sessionID: String, cwd: String) -> WuhuAgentsContextActor {
    if let existing = sessionContextActors[sessionID] {
      sessionContextActorLastAccess[sessionID] = Date()
      return existing
    }

    let actor = WuhuAgentsContextActor(cwd: cwd)
    sessionContextActors[sessionID] = actor
    sessionContextActorLastAccess[sessionID] = Date()

    if sessionContextActors.count > maxSessionContextActors {
      evictLeastRecentlyUsedSessionContextActor()
    }

    return actor
  }

  private func evictLeastRecentlyUsedSessionContextActor() {
    guard sessionContextActors.count > maxSessionContextActors else { return }

    guard let (oldestSessionID, _) = sessionContextActorLastAccess.min(by: { $0.value < $1.value }) else {
      return
    }

    sessionContextActors.removeValue(forKey: oldestSessionID)
    sessionContextActorLastAccess.removeValue(forKey: oldestSessionID)
  }

  private func subscribeLiveEvents(sessionID: String) -> AsyncStream<WuhuSessionStreamEvent> {
    AsyncStream(WuhuSessionStreamEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let token = UUID()
      liveSubscribers[sessionID, default: [:]][token] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeLiveSubscriber(sessionID: sessionID, token: token) }
      }
    }
  }

  private func removeLiveSubscriber(sessionID: String, token: UUID) {
    liveSubscribers[sessionID]?[token] = nil
    if liveSubscribers[sessionID]?.isEmpty == true {
      liveSubscribers[sessionID] = nil
    }
  }

  private func publishLiveEvent(sessionID: String, event: WuhuSessionStreamEvent) {
    guard var sessionSubs = liveSubscribers[sessionID], !sessionSubs.isEmpty else { return }
    for (token, continuation) in sessionSubs {
      continuation.yield(event)
      sessionSubs[token] = continuation
    }
    liveSubscribers[sessionID] = sessionSubs
  }

  private func beginPrompt(sessionID: String) {
    let n = (activePromptCount[sessionID] ?? 0) + 1
    activePromptCount[sessionID] = n
  }

  private func endPrompt(sessionID: String) {
    let old = activePromptCount[sessionID] ?? 0
    if old == 0 { return }
    let n = max(0, old - 1)
    if n == 0 {
      activePromptCount[sessionID] = nil
      publishLiveEvent(sessionID: sessionID, event: .idle)
    } else {
      activePromptCount[sessionID] = n
    }
  }

  private func beginPrompt(sessionID: String, token: UUID, agent: PiAgent.Agent) {
    let execution = ActiveExecution(
      agent: agent,
      cancel: {
        Task { await agent.abort() }
      },
    )
    activeExecutions[sessionID, default: [:]][token] = execution
    beginPrompt(sessionID: sessionID)
  }

  private func setActiveExecutionCancel(sessionID: String, token: UUID, cancel: @escaping @Sendable () -> Void) async {
    guard var executions = activeExecutions[sessionID],
          let existing = executions[token]
    else {
      return
    }
    executions[token] = ActiveExecution(agent: existing.agent, cancel: cancel)
    activeExecutions[sessionID] = executions
  }

  private func removeActiveExecution(sessionID: String, token: UUID) {
    activeExecutions[sessionID]?[token] = nil
    if activeExecutions[sessionID]?.isEmpty == true {
      activeExecutions[sessionID] = nil
    }
  }

  private func endPromptAsync(sessionID: String, token: UUID) async {
    removeActiveExecution(sessionID: sessionID, token: token)
    endPrompt(sessionID: sessionID)
    await applyPendingModelSelectionIfPossible(sessionID: sessionID)
    if activePromptCount.isEmpty {
      shutdownAgentLoopManager()
    }
  }

  private func isIdle(sessionID: String) -> Bool {
    (activePromptCount[sessionID] ?? 0) == 0
  }

  private func applyPendingModelSelectionIfPossible(sessionID: String) async {
    guard isIdle(sessionID: sessionID) else { return }
    guard lastAssistantMessageHadToolCalls[sessionID] != true else { return }
    guard let selection = pendingModelSelection[sessionID] else { return }
    do {
      _ = try await applyModelSelection(sessionID: sessionID, selection: selection)
      pendingModelSelection[sessionID] = nil
    } catch {
      // Best-effort: keep the pending selection so a later idle transition can retry.
    }
  }

  @discardableResult
  private func applyModelSelection(sessionID: String, selection: WuhuSessionSettings) async throws -> WuhuSessionEntry {
    let entry = try await store.appendEntry(sessionID: sessionID, payload: .sessionSettings(selection))
    publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
    return entry
  }

  private func makeRetryingStreamFn(
    base: @escaping StreamFn,
    sessionID: String,
    purpose: WuhuLLMRequestLogger.Purpose,
  ) -> StreamFn {
    let maxRetries = retryPolicy.maxRetries
    let initialBackoffSeconds = retryPolicy.initialBackoffSeconds
    let maxBackoffSeconds = retryPolicy.maxBackoffSeconds
    let jitterFraction = retryPolicy.jitterFraction
    let sleepFn = retryPolicy.sleep

    let nextBackoffSeconds: @Sendable (Int) -> Double = { retryIndex in
      let base = max(0, initialBackoffSeconds)
      let exp = pow(2.0, Double(max(0, retryIndex - 1)))
      let unclamped = base * exp
      let maxDelay = max(0, maxBackoffSeconds)
      let clamped = min(unclamped, maxDelay)

      let jitter = max(0, jitterFraction)
      guard jitter > 0, clamped > 0 else { return clamped }

      let sign: Double = (retryIndex % 2 == 0) ? -1 : 1
      return max(0, clamped * (1 + sign * jitter))
    }

    let sleepSeconds: @Sendable (Double) async throws -> Void = { seconds in
      let ns = UInt64(max(0, seconds) * 1_000_000_000)
      try await sleepFn(ns)
    }

    return { model, context, options in
      AsyncThrowingStream(AssistantMessageEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
        let task = Task {
          var retryIndex = 0
          while true {
            if Task.isCancelled {
              continuation.finish(throwing: CancellationError())
              return
            }

            var yieldedAnyEvent = false
            do {
              let underlying = try await base(model, context, options)
              do {
                for try await event in underlying {
                  yieldedAnyEvent = true
                  continuation.yield(event)
                }
                continuation.finish()
                return
              } catch {
                if Task.isCancelled {
                  continuation.finish(throwing: CancellationError())
                  return
                }

                let shouldRetry = yieldedAnyEvent == false && retryIndex < maxRetries
                if shouldRetry {
                  retryIndex += 1
                  let backoff = nextBackoffSeconds(retryIndex)
                  await self.appendLLMRetryEntry(
                    sessionID: sessionID,
                    purpose: purpose,
                    retryIndex: retryIndex,
                    maxRetries: maxRetries,
                    backoffSeconds: backoff,
                    error: error,
                  )
                  do {
                    try await sleepSeconds(backoff)
                  } catch {
                    continuation.finish(throwing: error)
                    return
                  }
                  continue
                }

                await self.appendLLMGiveUpEntry(sessionID: sessionID, purpose: purpose, maxRetries: maxRetries, error: error)
                continuation.finish(throwing: error)
                return
              }
            } catch {
              if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
                return
              }

              let shouldRetry = retryIndex < maxRetries
              if shouldRetry {
                retryIndex += 1
                let backoff = nextBackoffSeconds(retryIndex)
                await self.appendLLMRetryEntry(
                  sessionID: sessionID,
                  purpose: purpose,
                  retryIndex: retryIndex,
                  maxRetries: maxRetries,
                  backoffSeconds: backoff,
                  error: error,
                )
                do {
                  try await sleepSeconds(backoff)
                } catch {
                  continuation.finish(throwing: error)
                  return
                }
                continue
              }

              await self.appendLLMGiveUpEntry(sessionID: sessionID, purpose: purpose, maxRetries: maxRetries, error: error)
              continuation.finish(throwing: error)
              return
            }
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }
  }

  private func appendLLMRetryEntry(
    sessionID: String,
    purpose: WuhuLLMRequestLogger.Purpose,
    retryIndex: Int,
    maxRetries: Int,
    backoffSeconds: Double,
    error: any Error,
  ) async {
    let payload: WuhuEntryPayload = .custom(
      customType: WuhuLLMCustomEntryTypes.retry,
      data: WuhuLLMRetryEvent(
        purpose: purpose.rawValue,
        retryIndex: retryIndex,
        maxRetries: maxRetries,
        backoffSeconds: backoffSeconds,
        error: "\(error)",
      ).toJSONValue(),
    )

    do {
      let entry = try await store.appendEntry(sessionID: sessionID, payload: payload)
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
    } catch {
      // Best-effort: retry logging must never crash the server.
    }
  }

  private func appendLLMGiveUpEntry(
    sessionID: String,
    purpose: WuhuLLMRequestLogger.Purpose,
    maxRetries: Int,
    error: any Error,
  ) async {
    let payload: WuhuEntryPayload = .custom(
      customType: WuhuLLMCustomEntryTypes.giveUp,
      data: WuhuLLMGiveUpEvent(
        purpose: purpose.rawValue,
        maxRetries: maxRetries,
        error: "\(error)",
      ).toJSONValue(),
    )

    do {
      let entry = try await store.appendEntry(sessionID: sessionID, payload: payload)
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
    } catch {
      // Best-effort: give-up logging must never crash the server.
    }
  }

  private func ensureSessionLoop(sessionID: String) {
    guard sessionLoopContinuations[sessionID] == nil else { return }
    var capturedContinuation: AsyncStream<SessionLoopCommand>.Continuation?
    let stream = AsyncStream(SessionLoopCommand.self, bufferingPolicy: .unbounded) { continuation in
      capturedContinuation = continuation
    }
    sessionLoopContinuations[sessionID] = capturedContinuation
    agentLoopManagerContinuation?.yield(.startSession(sessionID: sessionID, stream: stream))
  }

  private func executeWorkItem(_ item: ExecutionWorkItem) async {
    let sessionID = item.sessionID
    let token = item.token
    let agent = item.agent

    let consumeTask = Task { [weak self] in
      guard let self else { return }
      await consumeAgentEvents(agent: agent, sessionID: sessionID, token: token)
    }

    var promptSucceeded = false
    do {
      try await agent.prompt(item.renderedInput)
      promptSucceeded = true
    } catch {
      await agent.abort()
    }

    if promptSucceeded {
      // Best-effort: ensure the agent's run task fully settles before we stop consuming events.
      // Avoid hanging forever if the agent fails to reach idle for some reason.
      let idleTimeoutTask = Task {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        await agent.abort()
      }
      await agent.waitForIdle()
      idleTimeoutTask.cancel()
    }

    if !promptSucceeded {
      // If the prompt failed, the events stream might never emit `agentEnd`.
      // Cancel consumption so we can finalize the session state.
      consumeTask.cancel()
    }

    let consumeTimeoutTask: Task<Void, Never>? = promptSucceeded
      ? Task {
        // Best-effort: agent.events should normally terminate after the run completes.
        // Avoid hanging the entire detached session loop if the stream doesn't close.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        consumeTask.cancel()
      }
      : nil

    _ = await consumeTask.value
    consumeTimeoutTask?.cancel()

    await endPromptAsync(sessionID: sessionID, token: token)
  }

  private func consumeAgentEvents(
    agent: PiAgent.Agent,
    sessionID: String,
    token: UUID,
  ) async {
    do {
      for try await event in agent.events {
        do {
          try await handleAgentEvent(event, sessionID: sessionID, token: token, continuation: nil)
        } catch {
          // Best-effort: ignore handler errors for detached execution loops.
        }
        if case .agentEnd = event { break }
      }
    } catch {
      // Best-effort: detached prompts don't surface errors to a caller.
    }
  }

  private func ensureAsyncBashCompletionListener() {
    guard asyncBashCompletionTask == nil else { return }
    asyncBashCompletionTask = Task { [weak self] in
      guard let self else { return }
      let stream = await asyncBashRegistry.subscribeCompletions()
      for await completion in stream {
        await handleAsyncBashCompletion(completion)
      }
    }
  }

  private func handleAsyncBashCompletion(_ completion: WuhuAsyncBashCompletion) async {
    guard completion.ownerID == instanceID else { return }
    guard let sessionID = completion.sessionID else { return }

    let stdoutData = (try? Data(contentsOf: URL(fileURLWithPath: completion.stdoutFile))) ?? Data()
    let stderrData = (try? Data(contentsOf: URL(fileURLWithPath: completion.stderrFile))) ?? Data()

    let stdoutText = String(decoding: stdoutData, as: UTF8.self)
    let stderrText = String(decoding: stderrData, as: UTF8.self)

    var combined = stdoutText
    if !stderrText.isEmpty {
      if !combined.isEmpty, !combined.hasSuffix("\n") { combined += "\n" }
      combined += stderrText
    }

    let truncation = ToolTruncation.truncateTail(combined)
    var outputText = truncation.content.isEmpty ? "(no output)" : truncation.content

    if truncation.truncated {
      let startLine = truncation.totalLines - truncation.outputLines + 1
      let endLine = truncation.totalLines
      if truncation.lastLinePartial {
        let last = combined.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lastSize = ToolTruncation.formatSize(last.utf8.count)
        if !outputText.isEmpty { outputText += "\n\n" }
        outputText +=
          "[Showing last \(ToolTruncation.formatSize(truncation.outputBytes)) of line \(endLine) (line is \(lastSize)). Full output: \(completion.stdoutFile) (stdout), \(completion.stderrFile) (stderr)]"
      } else if truncation.truncatedBy == "lines" {
        outputText +=
          "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines). Full output: \(completion.stdoutFile) (stdout), \(completion.stderrFile) (stderr)]"
      } else {
        outputText +=
          "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines) (\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit). Full output: \(completion.stdoutFile) (stdout), \(completion.stderrFile) (stderr)]"
      }
    }

    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let message: JSONValue = .object([
      "id": .string(completion.id),
      "started_at": .string(fmt.string(from: completion.startedAt)),
      "ended_at": .string(fmt.string(from: completion.endedAt)),
      "duration": .number(completion.durationSeconds),
      "exit_code": .number(Double(completion.exitCode)),
      "timed_out": .bool(completion.timedOut),
      "stdout_file": .string(completion.stdoutFile),
      "stderr_file": .string(completion.stderrFile),
      "output": .string(outputText),
    ])

    let jsonText = wuhuEncodeToolJSON(message)

    do {
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .message(.user(.init(
        user: WuhuUserMessage.unknownUser,
        content: [.text(text: jsonText, signature: nil)],
        timestamp: completion.endedAt,
      ))))
      publishLiveEvent(sessionID: sessionID, event: .entryAppended(entry))
    } catch {
      // Best-effort: task may outlive the session/service.
    }

    if let executions = activeExecutions[sessionID] {
      for (_, exec) in executions {
        await exec.agent.steer(.user(jsonText, timestamp: completion.endedAt))
      }
    }
  }
}
