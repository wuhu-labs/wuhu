import Foundation
import PiAgent
import PiAI

public enum WuhuPromptStreamEvent: Sendable, Hashable {
  case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
  case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
  case assistantTextDelta(String)
  case done
}

public actor WuhuService {
  private let store: any SessionStore

  public init(store: any SessionStore) {
    self.store = store
  }

  public func createSession(
    provider: WuhuProvider,
    model: String,
    systemPrompt: String,
    cwd: String = FileManager.default.currentDirectoryPath,
    parentSessionID: String? = nil,
  ) async throws -> WuhuSession {
    try await store.createSession(
      provider: provider,
      model: model,
      systemPrompt: systemPrompt,
      cwd: cwd,
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
    maxTurns: Int = 12,
    tools: [AnyAgentTool]? = nil,
    streamFn: @escaping StreamFn = PiAI.streamSimple,
  ) async throws -> AsyncThrowingStream<WuhuPromptStreamEvent, any Error> {
    let session = try await store.getSession(id: sessionID)
    let transcript = try await store.getEntries(sessionID: sessionID)

    let header = try Self.extractHeader(from: transcript, sessionID: sessionID)
    let messages = Self.extractContextMessages(from: transcript)

    let model = Model(id: session.model, provider: session.provider.piProvider)

    let resolvedTools = tools ?? WuhuTools.codingAgentTools(cwd: session.cwd)

    var effectiveSystemPrompt = header.systemPrompt
    effectiveSystemPrompt += "\n\nWorking directory: \(session.cwd)\nAll relative paths are resolved from this directory."

    var requestOptions = RequestOptions()
    if model.provider == .openai, model.id.contains("gpt-5") || model.id.contains("codex") {
      requestOptions.reasoningEffort = .low
    }

    let agent = PiAgent.Agent(opts: .init(
      initialState: .init(
        systemPrompt: effectiveSystemPrompt,
        model: model,
        tools: resolvedTools,
        messages: messages,
      ),
      requestOptions: requestOptions,
      streamFn: streamFn,
      maxTurns: maxTurns,
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
    transcript.compactMap { entry in
      guard case let .message(m) = entry.payload else { return nil }
      return m.toPiMessage()
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
    }
  }
}
