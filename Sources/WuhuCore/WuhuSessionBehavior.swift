import Foundation
import PiAI
import WuhuAPI

enum WuhuSessionStreamAction: Sendable, Hashable {
  case assistantTextDelta(String)
}

enum WuhuSessionExternalAction: Sendable, Hashable {
  case enqueueUser(id: QueueItemID, message: QueuedUserMessage, lane: UserQueueLane)
  case cancelUser(id: QueueItemID, lane: UserQueueLane)
  case enqueueSystem(id: QueueItemID, input: SystemUrgentInput, enqueuedAt: Date)

  case setPendingModelSelection(WuhuSessionSettings)
  case applyModelSelection(WuhuSessionSettings)
  case applyPendingModelIfPossible
}

enum WuhuSessionCommittedAction: Sendable, Hashable {
  case sessionUpdated(WuhuSession)
  case entryAppended(WuhuSessionEntry)
  case toolCallStatusUpdated(id: String, status: ToolCallStatus)
  case systemQueueUpdated(SystemUrgentQueueBackfill)
  case userQueueUpdated(lane: UserQueueLane, backfill: UserQueueBackfill)
  case settingsUpdated(SessionSettingsSnapshot)
  case statusUpdated(SessionStatusSnapshot)
}

struct WuhuSessionLoopState: Sendable, Equatable {
  var toolCallStatus: [String: ToolCallStatus]

  var entries: [WuhuSessionEntry]

  var settings: SessionSettingsSnapshot
  var status: SessionStatusSnapshot

  var systemUrgent: SystemUrgentQueueBackfill
  var steer: UserQueueBackfill
  var followUp: UserQueueBackfill

  static var empty: WuhuSessionLoopState {
    .init(
      toolCallStatus: [:],
      entries: [],
      settings: .init(effectiveModel: .init(provider: .openai, id: "unknown")),
      status: .init(status: .idle),
      systemUrgent: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )
  }
}

struct WuhuSessionBehavior: AgentBehavior {
  typealias State = WuhuSessionLoopState
  typealias CommittedAction = WuhuSessionCommittedAction
  typealias StreamAction = WuhuSessionStreamAction
  typealias ExternalAction = WuhuSessionExternalAction
  typealias ToolResult = AgentToolResult

  static var emptyState: WuhuSessionLoopState {
    .empty
  }

  let sessionID: SessionID
  let store: SQLiteSessionStore
  let runtimeConfig: WuhuSessionRuntimeConfig

  func loadState() async throws -> State {
    let parts = try await store.loadLoopStateParts(sessionID: sessionID)
    return .init(
      toolCallStatus: parts.toolCallStatus,
      entries: parts.entries,
      settings: parts.settings,
      status: parts.status,
      systemUrgent: parts.systemUrgent,
      steer: parts.steer,
      followUp: parts.followUp,
    )
  }

  func apply(_ action: CommittedAction, to state: inout State) {
    switch action {
    case let .sessionUpdated(session):
      // Session metadata is intentionally not part of the loop state shape.
      _ = session

    case let .entryAppended(entry):
      state.entries.append(entry)

    case let .toolCallStatusUpdated(id, status):
      state.toolCallStatus[id] = status

    case let .systemQueueUpdated(backfill):
      state.systemUrgent = backfill

    case let .userQueueUpdated(lane, backfill):
      switch lane {
      case .steer:
        state.steer = backfill
      case .followUp:
        state.followUp = backfill
      }

    case let .settingsUpdated(settings):
      state.settings = settings

    case let .statusUpdated(status):
      state.status = status
    }
  }

  func handle(_ action: ExternalAction, state _: State) async throws -> [CommittedAction] {
    switch action {
    case let .enqueueUser(id, message, lane):
      _ = try await store.enqueueUserMessage(sessionID: sessionID, id: id, message: message, lane: lane)
      let backfill = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: lane)
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      return [
        .userQueueUpdated(lane: lane, backfill: backfill),
        .statusUpdated(status),
      ]

    case let .cancelUser(id, lane):
      try await store.cancelUserMessage(sessionID: sessionID, id: id, lane: lane)
      let backfill = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: lane)
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      return [
        .userQueueUpdated(lane: lane, backfill: backfill),
        .statusUpdated(status),
      ]

    case let .enqueueSystem(id, input, enqueuedAt):
      _ = try await store.enqueueSystemInput(sessionID: sessionID, id: id, input: input, enqueuedAt: enqueuedAt)
      let backfill = try await store.loadSystemQueueBackfill(sessionID: sessionID)
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      return [
        .systemQueueUpdated(backfill),
        .statusUpdated(status),
      ]

    case let .setPendingModelSelection(selection):
      let settings = try await store.setPendingModelSelection(sessionID: sessionID, selection: selection)
      return [.settingsUpdated(settings)]

    case let .applyModelSelection(selection):
      let result = try await store.applyModelSelection(sessionID: sessionID, selection: selection)
      var actions: [CommittedAction] = [
        .sessionUpdated(result.session),
        .entryAppended(result.entry),
        .settingsUpdated(result.settings),
      ]
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      actions.append(.statusUpdated(status))
      return actions

    case .applyPendingModelIfPossible:
      guard let result = try await store.applyPendingModelIfPossible(sessionID: sessionID) else {
        return try await [.settingsUpdated(store.loadSettingsSnapshot(sessionID: sessionID))]
      }
      return [
        .sessionUpdated(result.session),
        .entryAppended(result.entry),
        .settingsUpdated(result.settings),
      ]
    }
  }

  func drainInterruptItems(state: State) async throws -> [CommittedAction] {
    if state.status.status == .stopped { return [] }
    let drained = try await store.drainInterruptCheckpoint(sessionID: sessionID)
    guard drained.didDrain else { return [] }
    var actions: [CommittedAction] = []
    actions.append(.sessionUpdated(drained.session))
    for entry in drained.entries {
      actions.append(.entryAppended(entry))
    }
    actions.append(.systemQueueUpdated(drained.systemUrgent))
    actions.append(.userQueueUpdated(lane: .steer, backfill: drained.steer))
    try await actions.append(.statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)))
    return actions
  }

  func drainTurnItems(state: State) async throws -> [CommittedAction] {
    if state.status.status == .stopped { return [] }
    let drained = try await store.drainTurnBoundary(sessionID: sessionID)
    guard drained.didDrain else { return [] }
    var actions: [CommittedAction] = []
    actions.append(.sessionUpdated(drained.session))
    for entry in drained.entries {
      actions.append(.entryAppended(entry))
    }
    actions.append(.userQueueUpdated(lane: .followUp, backfill: drained.followUp))
    try await actions.append(.statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)))
    return actions
  }

  func buildContext(state: State) -> Context {
    let header = (try? WuhuPromptPreparation.extractHeader(from: state.entries, sessionID: sessionID.rawValue))
    let systemPrompt = header?.systemPrompt ?? ""
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    return Context(systemPrompt: systemPrompt, messages: messages, tools: [])
  }

  func infer(context: Context, stream: AgentStreamSink<StreamAction>) async throws -> AssistantMessage {
    let session = try await store.getSession(id: sessionID.rawValue)
    let settings = try await store.loadSettingsSnapshot(sessionID: sessionID)

    let baseModel = Model(id: session.model, provider: session.provider.piProvider)
    let requestOptions = makeRequestOptions(model: baseModel, settings: settings)

    let tools = await runtimeConfig.tools()
    let streamFn = await runtimeConfig.streamFn()

    var effectiveSystemPrompt = context.systemPrompt ?? ""
    let ctxSection = await runtimeConfig.contextSection()
    if !ctxSection.isEmpty {
      effectiveSystemPrompt += ctxSection
    }
    effectiveSystemPrompt += "\n\nWorking directory: \(session.cwd)\nAll relative paths are resolved from this directory."

    let effectiveContext = Context(
      systemPrompt: effectiveSystemPrompt,
      messages: context.messages,
      tools: tools.map(\.tool),
    )

    let events = try await streamFn(baseModel, effectiveContext, requestOptions)

    var partial: AssistantMessage?
    var final: AssistantMessage?
    for try await event in events {
      switch event {
      case let .start(p):
        partial = p
      case let .textDelta(delta, p):
        stream.yield(.assistantTextDelta(delta))
        partial = p
      case let .done(message):
        final = message
      }
    }
    if let final { return final }
    if let partial { return partial }
    throw PiAIError.unsupported("No model output")
  }

  func persistAssistantEntry(_ message: AssistantMessage, state _: State) async throws -> [CommittedAction] {
    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(.assistant(message))),
      createdAt: message.timestamp,
    )

    var actions: [CommittedAction] = [
      .sessionUpdated(session),
      .entryAppended(entry),
    ]

    let calls = message.content.compactMap { block -> ToolCall? in
      if case let .toolCall(c) = block { return c }
      return nil
    }
    if !calls.isEmpty {
      let updates = try await store.upsertToolCallStatuses(sessionID: sessionID, calls: calls, status: .pending)
      for update in updates {
        actions.append(.toolCallStatusUpdated(id: update.id, status: update.status))
      }
    }

    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    actions.append(.statusUpdated(status))
    return actions
  }

  func toolWillExecute(_ call: ToolCall, state _: State) async throws -> [CommittedAction] {
    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .started)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    return [
      .toolCallStatusUpdated(id: updated.id, status: updated.status),
      .statusUpdated(status),
    ]
  }

  func executeToolCall(_ call: ToolCall) async throws -> ToolResult {
    let tools = await runtimeConfig.tools()
    guard let tool = tools.first(where: { $0.tool.name == call.name }) else {
      throw PiAIError.unsupported("Unknown tool: \(call.name)")
    }
    return try await tool.execute(toolCallId: call.id, args: call.arguments)
  }

  func toolDidExecute(_ call: ToolCall, result: ToolResult, state _: State) async throws -> [CommittedAction] {
    let now = Date()
    let toolResult: Message = .toolResult(.init(
      toolCallId: call.id,
      toolName: call.name,
      content: result.content,
      details: result.details,
      isError: false,
      timestamp: now,
    ))

    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(toolResult)),
      createdAt: now,
    )

    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .completed)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    return [
      .sessionUpdated(session),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: updated.id, status: updated.status),
      .statusUpdated(status),
    ]
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state _: State) async throws -> [CommittedAction] {
    let now = Date()
    let toolResult: Message = .toolResult(.init(
      toolCallId: call.id,
      toolName: call.name,
      content: [.text("[tool error] \(error)")],
      details: .object([
        "wuhu_tool_error": .string("\(error)"),
      ]),
      isError: true,
      timestamp: now,
    ))

    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(toolResult)),
      createdAt: now,
    )

    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .errored)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    return [
      .sessionUpdated(session),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: updated.id, status: updated.status),
      .statusUpdated(status),
    ]
  }

  func shouldCompact(state: State, usage _: Usage) -> Bool {
    let model = modelFromSettings(state.settings)
    let settings = WuhuCompactionSettings.load(model: model)
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    let estimate = WuhuCompactionEngine.estimateContextTokens(messages: messages)
    return WuhuCompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: settings)
  }

  func performCompaction(state: State) async throws -> [CommittedAction] {
    let session = try await store.getSession(id: sessionID.rawValue)
    let model = Model(id: session.model, provider: session.provider.piProvider)
    let settings = WuhuCompactionSettings.load(model: model)

    guard let prep = WuhuCompactionEngine.prepareCompaction(transcript: state.entries, settings: settings) else {
      return []
    }

    let streamFn = await runtimeConfig.streamFn()
    let requestOptions = makeRequestOptions(model: model, settings: state.settings)
    let summary = try await WuhuCompactionEngine.generateSummary(
      preparation: prep,
      model: model,
      settings: settings,
      requestOptions: requestOptions,
      streamFn: streamFn,
    )

    let payload: WuhuEntryPayload = .compaction(.init(
      summary: summary,
      tokensBefore: prep.tokensBefore,
      firstKeptEntryID: prep.firstKeptEntryID,
    ))

    let (_, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: payload,
      createdAt: Date(),
    )

    return try await [
      .entryAppended(entry),
      .statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)),
    ]
  }

  func staleToolCallIDs(in state: State) -> [String] {
    var finished: Set<String> = []
    for entry in state.entries {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .toolResult(t) = m else { continue }
      finished.insert(t.toolCallId)
    }

    return state.toolCallStatus.compactMap { id, status in
      guard status == .started || status == .pending else { return nil }
      return finished.contains(id) ? nil : id
    }.sorted()
  }

  func recoverStaleToolCall(id: String, state: State) async throws -> [CommittedAction] {
    // Avoid double-repair.
    if state.entries.contains(where: { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .toolResult(t) = m else { return false }
      return t.toolCallId == id
    }) {
      let updated = try await store.setToolCallStatus(sessionID: sessionID, id: id, status: .errored)
      return [.toolCallStatusUpdated(id: updated.id, status: updated.status)]
    }

    let toolName: String = {
      for entry in state.entries.reversed() {
        guard case let .message(m) = entry.payload else { continue }
        guard case let .assistant(a) = m else { continue }
        for block in a.content {
          guard case let .toolCall(callID, name, _) = block else { continue }
          if callID == id { return name }
        }
      }
      return "unknown"
    }()

    let now = Date()
    let repaired: Message = .toolResult(.init(
      toolCallId: id,
      toolName: toolName,
      content: [.text(WuhuToolRepairer.lostToolResultText)],
      details: .object([
        "wuhu_repair": .string("stale_tool_call"),
        "reason": .string("lost"),
      ]),
      isError: true,
      timestamp: now,
    ))

    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(repaired)),
      createdAt: now,
    )

    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: id, status: .errored)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    return [
      .sessionUpdated(session),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: updated.id, status: updated.status),
      .statusUpdated(status),
    ]
  }

  func hasWork(state: State) -> Bool {
    switch state.status.status {
    case .stopped:
      false
    case .running:
      true
    case .idle:
      false
    }
  }
}

private func makeRequestOptions(model: Model, settings: SessionSettingsSnapshot) -> RequestOptions {
  var requestOptions = RequestOptions()

  // Max tokens: use model spec (maxOutput / 3) or a generous fallback.
  requestOptions.maxTokens = WuhuModelCatalog.defaultMaxTokens(for: model.id)

  if let effort = settings.effectiveReasoningEffort {
    requestOptions.reasoningEffort = effort
  } else if model.provider == .openai || model.provider == .openaiCodex,
            model.id.contains("gpt-5") || model.id.contains("codex")
  {
    requestOptions.reasoningEffort = .low
  }
  if model.provider == .anthropic {
    requestOptions.anthropicPromptCaching = .init(mode: .automatic)
    requestOptions.maxTokens = requestOptions.maxTokens ?? 4096
  }
  return requestOptions
}

private func modelFromSettings(_ settings: SessionSettingsSnapshot) -> Model {
  let provider: Provider = switch settings.effectiveModel.provider.rawValue {
  case ProviderID.openai.rawValue:
    .openai
  case ProviderID.openaiCodex.rawValue:
    .openaiCodex
  case ProviderID.anthropic.rawValue:
    .anthropic
  default:
    .openai
  }
  return .init(id: settings.effectiveModel.id, provider: provider)
}
