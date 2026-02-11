import Foundation
import PiAgent
import PiAI
import WuhuAPI

public actor WuhuService {
  private let store: any SessionStore
  private var sessionContextActors: [String: WuhuAgentsContextActor] = [:]
  private var sessionContextActorLastAccess: [String: Date] = [:]
  private let maxSessionContextActors = 64

  private var liveSubscribers: [String: [UUID: AsyncStream<WuhuSessionStreamEvent>.Continuation]] = [:]
  private var activePromptCount: [String: Int] = [:]

  public init(store: any SessionStore) {
    self.store = store
  }

  public func createSession(
    provider: WuhuProvider,
    model: String,
    systemPrompt: String,
    environment: WuhuEnvironment,
    runnerName: String? = nil,
    parentSessionID: String? = nil,
  ) async throws -> WuhuSession {
    try await store.createSession(
      provider: provider,
      model: model,
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
    tools: [AnyAgentTool]? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let session = try await store.getSession(id: sessionID)
    var transcript = try await store.getEntries(sessionID: sessionID)

    let header = try Self.extractHeader(from: transcript, sessionID: sessionID)

    let model = Model(id: session.model, provider: session.provider.piProvider)

    let resolvedTools = tools ?? WuhuTools.codingAgentTools(cwd: session.cwd)

    var effectiveSystemPrompt = header.systemPrompt
    let injectedContext = await sessionContextActor(for: sessionID, cwd: session.cwd).contextSection()
    if !injectedContext.isEmpty {
      effectiveSystemPrompt += injectedContext
    }
    effectiveSystemPrompt += "\n\nWorking directory: \(session.cwd)\nAll relative paths are resolved from this directory."

    var requestOptions = RequestOptions()
    if model.provider == .openai, model.id.contains("gpt-5") || model.id.contains("codex") {
      requestOptions.reasoningEffort = .low
    }

    let compactionSettings = WuhuCompactionSettings.load(model: model)
    transcript = try await maybeAutoCompact(
      sessionID: sessionID,
      transcript: transcript,
      model: model,
      requestOptions: requestOptions,
      compactionSettings: compactionSettings,
      input: input,
      streamFn: streamFn,
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
      streamFn: streamFn,
    ))

    beginPrompt(sessionID: sessionID)
    let userEntry = try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(.user(input))))
    publishLiveEvent(sessionID: sessionID, event: .entryAppended(userEntry))

    return AsyncThrowingStream(WuhuSessionStreamEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
      let task = Task {
        do {
          defer { Task { await self.endPrompt(sessionID: sessionID) } }

          continuation.yield(.entryAppended(userEntry))

          let consumeTask = Task {
            for try await event in agent.events {
              try await self.handleAgentEvent(event, sessionID: sessionID, continuation: continuation)
              if case .agentEnd = event { break }
            }
          }
          defer { consumeTask.cancel() }
          try await agent.prompt(input)
          _ = try await consumeTask.value

          continuation.yield(.done)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
        Task { await agent.abort() }
        Task { await self.endPrompt(sessionID: sessionID) }
      }
    }
  }

  public func promptDetached(
    sessionID: String,
    input: String,
    tools: [AnyAgentTool]? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) async throws -> WuhuPromptDetachedResponse {
    let session = try await store.getSession(id: sessionID)
    var transcript = try await store.getEntries(sessionID: sessionID)

    let header = try Self.extractHeader(from: transcript, sessionID: sessionID)
    let model = Model(id: session.model, provider: session.provider.piProvider)

    let resolvedTools = tools ?? WuhuTools.codingAgentTools(cwd: session.cwd)

    var effectiveSystemPrompt = header.systemPrompt
    let injectedContext = await sessionContextActor(for: sessionID, cwd: session.cwd).contextSection()
    if !injectedContext.isEmpty {
      effectiveSystemPrompt += injectedContext
    }
    effectiveSystemPrompt += "\n\nWorking directory: \(session.cwd)\nAll relative paths are resolved from this directory."

    var requestOptions = RequestOptions()
    if model.provider == .openai, model.id.contains("gpt-5") || model.id.contains("codex") {
      requestOptions.reasoningEffort = .low
    }

    let compactionSettings = WuhuCompactionSettings.load(model: model)
    transcript = try await maybeAutoCompact(
      sessionID: sessionID,
      transcript: transcript,
      model: model,
      requestOptions: requestOptions,
      compactionSettings: compactionSettings,
      input: input,
      streamFn: streamFn,
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
      streamFn: streamFn,
    ))

    beginPrompt(sessionID: sessionID)
    let userEntry = try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(.user(input))))
    publishLiveEvent(sessionID: sessionID, event: .entryAppended(userEntry))

    Task {
      do {
        defer { Task { await self.endPrompt(sessionID: sessionID) } }

        let consumeTask = Task {
          do {
            for try await event in agent.events {
              try await self.handleAgentEvent(event, sessionID: sessionID, continuation: nil)
              if case .agentEnd = event { break }
            }
          } catch {
            // Best-effort: detached prompts don't surface errors to a caller.
          }
        }
        defer { consumeTask.cancel() }

        try await agent.prompt(input)
        _ = try await consumeTask.value
      } catch {
        await agent.abort()
      }
    }

    return WuhuPromptDetachedResponse(userEntry: userEntry)
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
    continuation: AsyncThrowingStream<WuhuSessionStreamEvent, any Error>.Continuation?,
  ) async throws {
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

  private static func extractContextMessages(from transcript: [WuhuSessionEntry]) -> [Message] {
    let headerIndex = transcript.firstIndex(where: { $0.parentEntryID == nil }) ?? 0

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

    for entry in transcript[startIndex...] {
      guard case let .message(m) = entry.payload else { continue }
      guard let pi = m.toPiMessage() else { continue }
      messages.append(pi)
    }

    return messages
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

  private func isIdle(sessionID: String) -> Bool {
    (activePromptCount[sessionID] ?? 0) == 0
  }
}
