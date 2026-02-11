import Foundation
import PiAgent
import PiAI
import WuhuAPI

public enum WuhuPromptStreamEvent: Sendable, Hashable {
  case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
  case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
  case assistantTextDelta(String)
  case done
}

public actor WuhuService {
  private let store: any SessionStore
  private var sessionContextActors: [String: WuhuAgentsContextActor] = [:]
  private var sessionContextActorLastAccess: [String: Date] = [:]
  private let maxSessionContextActors = 64

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

  public func promptStream(
    sessionID: String,
    input: String,
    tools: [AnyAgentTool]? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) async throws -> AsyncThrowingStream<WuhuPromptStreamEvent, any Error> {
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

    return AsyncThrowingStream(WuhuPromptStreamEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
      let task = Task {
        do {
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

      _ = try await store.appendEntry(sessionID: sessionID, payload: .compaction(.init(
        summary: summary,
        tokensBefore: preparation.tokensBefore,
        firstKeptEntryID: preparation.firstKeptEntryID,
      )))

      current = try await store.getEntries(sessionID: sessionID)
    }

    return current
  }

  private func handleAgentEvent(
    _ event: AgentEvent,
    sessionID: String,
    continuation: AsyncThrowingStream<WuhuPromptStreamEvent, any Error>.Continuation,
  ) async throws {
    switch event {
    case let .toolExecutionStart(toolCallId, toolName, args):
      continuation.yield(.toolExecutionStart(toolCallId: toolCallId, toolName: toolName, args: args))
      try await store.appendEntry(sessionID: sessionID, payload: .toolExecution(.init(
        phase: .start,
        toolCallId: toolCallId,
        toolName: toolName,
        arguments: args,
      )))

    case let .toolExecutionEnd(toolCallId, toolName, result, isError):
      continuation.yield(.toolExecutionEnd(toolCallId: toolCallId, toolName: toolName, result: result, isError: isError))
      try await store.appendEntry(sessionID: sessionID, payload: .toolExecution(.init(
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

    case let .messageUpdate(message, assistantEvent):
      if case .assistant = message, case let .textDelta(delta, _) = assistantEvent {
        continuation.yield(.assistantTextDelta(delta))
      }

    case let .messageEnd(message):
      try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(message)))

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
}
