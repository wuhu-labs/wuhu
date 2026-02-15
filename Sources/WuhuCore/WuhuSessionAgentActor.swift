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
  private weak var service: WuhuService?

  private var agent: PiAgent.Agent?
  private var eventsConsumerTask: Task<Void, Never>?

  private var runningPromptTask: Task<Void, Never>?

  private var pendingModelSelection: WuhuSessionSettings?
  private var lastAssistantMessageHadToolCalls: Bool = false

  private let runEndStream: AsyncStream<Void>
  private let runEndContinuation: AsyncStream<Void>.Continuation

  init(sessionID: String, store: any SessionStore, eventHub: WuhuLiveEventHub, service: WuhuService) {
    self.sessionID = sessionID
    self.store = store
    self.eventHub = eventHub
    self.service = service

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
    .init(activePromptCount: (runningPromptTask == nil) ? 0 : 1)
  }

  func stopSession(user: String?) async throws -> WuhuStopSessionResponse {
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

  func runDetached(_ prepared: PreparedPrompt) async throws {
    if runningPromptTask != nil {
      throw PiAIError.unsupported("Session is already executing")
    }

    let agent = try await ensureAgent(prepared: prepared)
    ensureEventConsumer(agent: agent)

    runningPromptTask = Task { [weak self] in
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
  }

  private func clearRunningTask() {
    runningPromptTask = nil
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

    eventsConsumerTask = Task { [weak service] in
      guard let service else { return }
      do {
        for try await event in agent.events {
          do {
            try await service.handleAgentEvent(event, sessionID: sessionID)
          } catch {
            // Best-effort: ignore handler errors for long-lived session agents.
          }
          if case let .messageEnd(message) = event, case let .assistant(a) = message {
            recordAssistantMessageEnd(a)
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
}
