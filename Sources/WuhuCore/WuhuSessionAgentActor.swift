import Foundation
import PiAgent
import PiAI
import WuhuAPI

actor WuhuSessionAgentActor {
  struct PreparedPrompt: Sendable {
    var renderedInput: String
    var systemPrompt: String
    var model: Model
    var tools: [AnyAgentTool]
    var messages: [Message]
    var requestOptions: RequestOptions
    var streamFn: StreamFn
  }

  let sessionID: String
  private let store: any SessionStore
  private let eventHub: WuhuLiveEventHub
  private let llmRequestLogger: WuhuLLMRequestLogger?
  private let retryPolicy: WuhuLLMRetryPolicy
  private let asyncBashRegistry: WuhuAsyncBashRegistry
  private let instanceID: String

  private var agent: PiAgent.Agent?
  private var eventsConsumerTask: Task<Void, Never>?

  private var runningPromptTask: Task<Void, Never>?

  private struct QueuedPrompt {
    var id: UUID
    var input: String
    var user: String?
    var tools: [AnyAgentTool]?
    var streamFn: StreamFn
    var continuation: CheckedContinuation<WuhuPromptDetachedResponse, Error>
  }

  private var promptQueue: [QueuedPrompt] = []
  private var promptQueueTask: Task<Void, Never>?

  private var pendingModelSelection: WuhuSessionSettings?
  private var lastAssistantMessageHadToolCalls: Bool = false

  private var contextActor: WuhuAgentsContextActor?
  private var contextCwd: String?

  private let runEndStream: AsyncStream<Void>
  private let runEndContinuation: AsyncStream<Void>.Continuation

  init(
    sessionID: String,
    store: any SessionStore,
    eventHub: WuhuLiveEventHub,
    llmRequestLogger: WuhuLLMRequestLogger?,
    retryPolicy: WuhuLLMRetryPolicy,
    asyncBashRegistry: WuhuAsyncBashRegistry,
    instanceID: String,
  ) {
    self.sessionID = sessionID
    self.store = store
    self.eventHub = eventHub
    self.llmRequestLogger = llmRequestLogger
    self.retryPolicy = retryPolicy
    self.asyncBashRegistry = asyncBashRegistry
    self.instanceID = instanceID

    let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    runEndStream = stream
    runEndContinuation = continuation
  }

  deinit {
    runningPromptTask?.cancel()
    eventsConsumerTask?.cancel()
  }

  func abort() async {
    runningPromptTask?.cancel()
    runningPromptTask = nil
    if let agent {
      await agent.abort()
    }
  }

  func isIdle() -> Bool {
    runningPromptTask == nil
  }

  func promptDetached(
    input: String,
    user: String?,
    tools: [AnyAgentTool]?,
    streamFn: @escaping StreamFn,
  ) async throws -> WuhuPromptDetachedResponse {
    let queuedID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        promptQueue.append(.init(id: queuedID, input: input, user: user, tools: tools, streamFn: streamFn, continuation: continuation))
        startPromptQueueIfNeeded()
      }
    } onCancel: {
      Task { await self.cancelQueuedPrompt(id: queuedID) }
    }
  }

  func setModelSelection(_ selection: WuhuSessionSettings) async throws -> Bool {
    if runningPromptTask == nil, !lastAssistantMessageHadToolCalls {
      pendingModelSelection = nil
      try await applyModelSelection(selection)
      return true
    }

    pendingModelSelection = selection
    return false
  }

  func inProcessExecutionInfo() -> WuhuInProcessExecutionInfo {
    .init(activePromptCount: (runningPromptTask == nil ? 0 : 1) + promptQueue.count)
  }

  func stopSession(user: String?) async throws -> WuhuStopSessionResponse {
    cancelQueuedPrompts()
    _ = try await store.getSession(id: sessionID)

    let transcript = try await store.getEntries(sessionID: sessionID)
    let inferred = WuhuSessionExecutionInference.infer(from: transcript)
    let inProcessCount = (runningPromptTask == nil) ? 0 : 1

    guard inferred.state == .executing || inProcessCount > 0 else {
      return .init(repairedEntries: [], stopEntry: nil)
    }

    await abort()

    var updatedTranscript = try await store.getEntries(sessionID: sessionID)
    let toolRepair = try await WuhuToolRepairer.repairMissingToolResultsIfNeeded(
      sessionID: sessionID,
      transcript: updatedTranscript,
      mode: .stopped,
      store: store,
      eventHub: eventHub
    )
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
    await eventHub.publish(sessionID: sessionID, event: .entryAppended(stopEntry))

    await eventHub.publish(sessionID: sessionID, event: .idle)

    return .init(repairedEntries: toolRepair.repairEntries, stopEntry: stopEntry)
  }

  func steerUser(_ text: String, timestamp: Date) async {
    guard let agent else { return }
    await agent.steer(.user(text, timestamp: timestamp))
  }

  private func runDetached(_ prepared: PreparedPrompt) async throws -> Task<Void, Never> {
    if runningPromptTask != nil {
      throw PiAIError.unsupported("Session is already executing")
    }

    let agent = try await ensureAgent(prepared: prepared)
    ensureEventConsumer(agent: agent)

    let task = Task { [weak self] in
      guard let self else { return }
      defer { Task { await self.clearRunningTask() } }

      var promptSucceeded = false
      do {
        try await agent.prompt(prepared.renderedInput)
        promptSucceeded = true
      } catch {
        await agent.abort()
      }

      if promptSucceeded {
        let idleTimeoutTask = Task {
          try? await Task.sleep(nanoseconds: 10_000_000_000)
          await agent.abort()
        }
        await agent.waitForIdle()
        idleTimeoutTask.cancel()
      }

      await self.waitForRunEnd(timeoutNanoseconds: 5_000_000_000)
      await self.applyPendingModelSelectionIfPossible()
      await eventHub.publish(sessionID: sessionID, event: .idle)
    }
    runningPromptTask = task
    return task
  }

  private func clearRunningTask() {
    runningPromptTask = nil
  }

  private func startPromptQueueIfNeeded() {
    guard promptQueueTask == nil else { return }
    promptQueueTask = Task { [weak self] in
      await self?.processPromptQueue()
    }
  }

  private func cancelQueuedPrompts() {
    promptQueueTask?.cancel()
    promptQueueTask = nil

    let queued = promptQueue
    promptQueue = []
    for q in queued {
      q.continuation.resume(throwing: PiAIError.unsupported("Session was stopped"))
    }
  }

  private func cancelQueuedPrompt(id: UUID) {
    guard let idx = promptQueue.firstIndex(where: { $0.id == id }) else { return }
    let q = promptQueue.remove(at: idx)
    q.continuation.resume(throwing: CancellationError())
  }

  private func processPromptQueue() async {
    while true {
      if Task.isCancelled { break }
      guard !promptQueue.isEmpty else { break }

      let next = promptQueue.removeFirst()
      do {
        let (response, runTask) = try await startAndRunPrompt(
          input: next.input,
          user: next.user,
          tools: next.tools,
          streamFn: next.streamFn,
        )
        next.continuation.resume(returning: response)
        await runTask.value
      } catch {
        next.continuation.resume(throwing: error)
      }
    }

    promptQueueTask = nil
  }

  private func startAndRunPrompt(
    input: String,
    user: String?,
    tools: [AnyAgentTool]?,
    streamFn: @escaping StreamFn,
  ) async throws -> (WuhuPromptDetachedResponse, Task<Void, Never>) {
    let effectiveUser = WuhuPromptPreparation.normalizeUser(user)
    let session = try await store.getSession(id: sessionID)
    var transcript = try await store.getEntries(sessionID: sessionID)

    let toolRepair = try await WuhuToolRepairer.repairMissingToolResultsIfNeeded(
      sessionID: sessionID,
      transcript: transcript,
      mode: .lost,
      store: store,
      eventHub: eventHub
    )
    transcript = toolRepair.transcript

    _ = try await maybeAppendGroupChatReminderIfNeeded(
      transcript: transcript,
      promptingUser: effectiveUser,
    )
    transcript = try await store.getEntries(sessionID: sessionID)

    let header = try WuhuPromptPreparation.extractHeader(from: transcript, sessionID: sessionID)
    let settingsOverride = WuhuPromptPreparation.extractLatestSessionSettings(from: transcript)
    let model = Model(id: session.model, provider: session.provider.piProvider)

    let loggedAgentStreamFn = llmRequestLogger?.makeLoggedStreamFn(base: streamFn, sessionID: sessionID, purpose: .agent) ?? streamFn
    let loggedCompactionStreamFn = llmRequestLogger?.makeLoggedStreamFn(base: streamFn, sessionID: sessionID, purpose: .compaction) ?? streamFn
    let agentStreamFn = makeRetryingStreamFn(base: loggedAgentStreamFn, purpose: .agent)
    let compactionStreamFn = makeRetryingStreamFn(base: loggedCompactionStreamFn, purpose: .compaction)

    let resolvedTools = tools ?? WuhuTools.codingAgentTools(
      cwd: session.cwd,
      asyncBash: .init(registry: asyncBashRegistry, sessionID: sessionID, ownerID: instanceID),
    )

    var effectiveSystemPrompt = header.systemPrompt
    let injectedContext = await sessionContextSection(cwd: session.cwd)
    if !injectedContext.isEmpty {
      effectiveSystemPrompt += injectedContext
    }
    effectiveSystemPrompt += "\n\nWorking directory: \(session.cwd)\nAll relative paths are resolved from this directory."

    let requestOptions = makeRequestOptions(model: model, header: header, settingsOverride: settingsOverride)

    let compactionSettings = WuhuCompactionSettings.load(model: model)
    let groupChatActive = WuhuGroupChat.reminderEntryIndex(in: transcript) != nil
    let renderedInput = groupChatActive ? WuhuGroupChat.renderPromptInput(user: effectiveUser, input: input) : input
    transcript = try await maybeAutoCompact(
      transcript: transcript,
      model: model,
      requestOptions: requestOptions,
      compactionSettings: compactionSettings,
      input: renderedInput,
      streamFn: compactionStreamFn,
    )

    let messages = WuhuPromptPreparation.extractContextMessages(from: transcript)

    let userEntry = try await store.appendEntry(sessionID: sessionID, payload: .message(.user(.init(
      user: effectiveUser,
      content: [.text(text: input, signature: nil)],
      timestamp: Date(),
    ))))
    await eventHub.publish(sessionID: sessionID, event: .entryAppended(userEntry))

    let prepared = PreparedPrompt(
      renderedInput: renderedInput,
      systemPrompt: effectiveSystemPrompt,
      model: model,
      tools: resolvedTools,
      messages: messages,
      requestOptions: requestOptions,
      streamFn: agentStreamFn,
    )
    let runTask = try await runDetached(prepared)

    return (WuhuPromptDetachedResponse(userEntry: userEntry), runTask)
  }

  private func waitForRunEnd(timeoutNanoseconds: UInt64) async {
    let waitTask = Task { [runEndStream] in
      var iterator = runEndStream.makeAsyncIterator()
      _ = await iterator.next()
    }
    let timeoutTask = Task {
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
      waitTask.cancel()
    }
    _ = await waitTask.value
    timeoutTask.cancel()
  }

  private func ensureAgent(prepared: PreparedPrompt) async throws -> PiAgent.Agent {
    if let agent {
      await agent.setSystemPrompt(prepared.systemPrompt)
      await agent.setModel(prepared.model)
      await agent.setTools(prepared.tools)
      await agent.setRequestOptions(prepared.requestOptions)
      await agent.replaceMessages(prepared.messages)
      return agent
    }

    let agent = PiAgent.Agent(opts: .init(
      initialState: .init(
        systemPrompt: prepared.systemPrompt,
        model: prepared.model,
        tools: prepared.tools,
        messages: prepared.messages,
      ),
      requestOptions: prepared.requestOptions,
      streamFn: prepared.streamFn,
    ))
    self.agent = agent
    return agent
  }

  private func ensureEventConsumer(agent: PiAgent.Agent) {
    guard eventsConsumerTask == nil else { return }

    let sessionID = sessionID
    let runEndContinuation = runEndContinuation

    eventsConsumerTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await event in agent.events {
          do {
            try await self.handleAgentEvent(event, sessionID: sessionID)
          } catch {
            // Best-effort: ignore handler errors for long-lived session agents.
          }
          if case let .messageEnd(message) = event, case let .assistant(a) = message {
            await self.recordAssistantMessageEnd(a)
          }
          if case .agentEnd = event {
            runEndContinuation.yield(())
          }
        }
      } catch {
        // Best-effort: ignore stream termination errors.
      }
    }
  }

  private func handleAgentEvent(
    _ event: AgentEvent,
    sessionID: String,
  ) async throws {
    switch event {
    case let .toolExecutionStart(toolCallId, toolName, args):
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: toolCallId,
        toolName: toolName,
        arguments: args,
      )))
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))

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
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))

    case let .messageUpdate(message, assistantEvent):
      if case .assistant = message, case let .textDelta(delta, _) = assistantEvent {
        await eventHub.publish(sessionID: sessionID, event: .assistantTextDelta(delta))
      }

    case let .messageEnd(message):
      if case .user = message {
        break
      }
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(message)))
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))

    default:
      break
    }
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

  private func recordAssistantMessageEnd(_ a: AssistantMessage) {
    lastAssistantMessageHadToolCalls = a.content.contains { if case .toolCall = $0 { return true }; return false }
  }

  private func applyPendingModelSelectionIfPossible() async {
    guard !lastAssistantMessageHadToolCalls else { return }
    guard let selection = pendingModelSelection else { return }

    do {
      try await applyModelSelection(selection)
      pendingModelSelection = nil
    } catch {
      // Best-effort: keep pending selection.
    }
  }

  @discardableResult
  private func applyModelSelection(_ selection: WuhuSessionSettings) async throws -> WuhuSessionEntry {
    let entry = try await store.appendEntry(sessionID: sessionID, payload: .sessionSettings(selection))
    await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))
    return entry
  }

  private func sessionContextSection(cwd: String) async -> String {
    if contextActor == nil || contextCwd != cwd {
      contextActor = WuhuAgentsContextActor(cwd: cwd)
      contextCwd = cwd
    }
    guard let contextActor else { return "" }
    return await contextActor.contextSection()
  }

  private func maybeAppendGroupChatReminderIfNeeded(
    transcript: [WuhuSessionEntry],
    promptingUser: String,
  ) async throws -> WuhuSessionEntry? {
    if WuhuGroupChat.reminderEntryIndex(in: transcript) != nil {
      return nil
    }

    guard let firstUser = WuhuPromptPreparation.firstPromptingUser(in: transcript) else {
      return nil
    }

    guard firstUser != promptingUser else {
      return nil
    }

    let reminderEntry = try await store.appendEntry(
      sessionID: sessionID,
      payload: .message(WuhuGroupChat.makeReminderMessage(previousUser: firstUser)),
    )
    await eventHub.publish(sessionID: sessionID, event: .entryAppended(reminderEntry))
    return reminderEntry
  }

  private func maybeAutoCompact(
    transcript: [WuhuSessionEntry],
    model: Model,
    requestOptions: RequestOptions,
    compactionSettings: WuhuCompactionSettings,
    input: String,
    streamFn: @escaping StreamFn,
  ) async throws -> [WuhuSessionEntry] {
    var current = transcript

    for _ in 0 ..< 3 {
      let contextMessages = WuhuPromptPreparation.extractContextMessages(from: current)
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
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))

      current = try await store.getEntries(sessionID: sessionID)
    }

    return current
  }

  private func makeRequestOptions(
    model: Model,
    header: WuhuSessionHeader,
    settingsOverride: WuhuSessionSettings?,
  ) -> RequestOptions {
    var requestOptions = RequestOptions()
    let sessionEffort = settingsOverride?.reasoningEffort ?? WuhuPromptPreparation.extractReasoningEffort(from: header)
    if let effort = sessionEffort {
      requestOptions.reasoningEffort = effort
    } else if model.provider == .openai || model.provider == .openaiCodex,
              model.id.contains("gpt-5") || model.id.contains("codex")
    {
      requestOptions.reasoningEffort = .low
    }
    return requestOptions
  }

  private func makeRetryingStreamFn(
    base: @escaping StreamFn,
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

                await self.appendLLMGiveUpEntry(purpose: purpose, maxRetries: maxRetries, error: error)
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

              await self.appendLLMGiveUpEntry(purpose: purpose, maxRetries: maxRetries, error: error)
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
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))
    } catch {
      // Best-effort: retry logging must never crash the server.
    }
  }

  private func appendLLMGiveUpEntry(
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
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))
    } catch {
      // Best-effort: give-up logging must never crash the server.
    }
  }
}
