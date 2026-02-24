import Dependencies
import Foundation
import IdentifiedCollections
import PiAI
import WuhuAPI
import WuhuClient
import WuhuCore

// MARK: - API Client Dependency

struct APIClient: Sendable {
  var listSessions: @Sendable () async throws -> [WuhuSession]
  var getSession: @Sendable (_ id: String) async throws -> WuhuGetSessionResponse
  var createSession: @Sendable (_ request: WuhuCreateSessionRequest) async throws -> WuhuSession
  var listEnvironments: @Sendable () async throws -> [WuhuEnvironmentDefinition]
  var listWorkspaceDocs: @Sendable () async throws -> [WuhuWorkspaceDocSummary]
  var readWorkspaceDoc: @Sendable (_ path: String) async throws -> WuhuWorkspaceDoc
  var enqueue: @Sendable (_ sessionID: String, _ input: String, _ user: String?) async throws -> String
  var stopSession: @Sendable (_ sessionID: String) async throws -> WuhuStopSessionResponse
  var setSessionModel: @Sendable (
    _ sessionID: String,
    _ provider: WuhuProvider,
    _ model: String?,
    _ reasoningEffort: ReasoningEffort?
  ) async throws -> WuhuSetSessionModelResponse
}

extension APIClient: DependencyKey {
  static let liveValue: APIClient = {
    let urlString = UserDefaults.standard.string(forKey: "wuhuServerURL") ?? "http://localhost:8080"
    let baseURL = URL(string: urlString) ?? URL(string: "http://localhost:8080")!
    let client = WuhuClient(baseURL: baseURL)
    return APIClient(
      listSessions: { try await client.listSessions() },
      getSession: { try await client.getSession(id: $0) },
      createSession: { try await client.createSession($0) },
      listEnvironments: { try await client.listEnvironments() },
      listWorkspaceDocs: { try await client.listWorkspaceDocs() },
      readWorkspaceDoc: { try await client.readWorkspaceDoc(path: $0) },
      enqueue: { sessionID, input, user in
        try await client.enqueue(sessionID: sessionID, input: input, user: user)
      },
      stopSession: { try await client.stopSession(sessionID: $0) },
      setSessionModel: { sessionID, provider, model, reasoningEffort in
        try await client.setSessionModel(
          sessionID: sessionID, provider: provider, model: model, reasoningEffort: reasoningEffort
        )
      },
    )
  }()

  static let previewValue = APIClient(
    listSessions: { [] },
    getSession: { _ in
      WuhuGetSessionResponse(
        session: WuhuSession(
          id: "preview",
          provider: .anthropic,
          model: "claude-sonnet-4-6",
          environment: WuhuEnvironment(name: "preview", type: .local, path: "/tmp"),
          cwd: "/tmp",
          parentSessionID: nil,
          createdAt: Date(),
          updatedAt: Date(),
          headEntryID: 0,
          tailEntryID: 0,
        ),
        transcript: [],
      )
    },
    createSession: { _ in
      WuhuSession(
        id: "preview",
        provider: .anthropic,
        model: "claude-sonnet-4-6",
        environment: WuhuEnvironment(name: "preview", type: .local, path: "/tmp"),
        cwd: "/tmp",
        parentSessionID: nil,
        createdAt: Date(),
        updatedAt: Date(),
        headEntryID: 0,
        tailEntryID: 0,
      )
    },
    listEnvironments: { [] },
    listWorkspaceDocs: { [] },
    readWorkspaceDoc: { _ in WuhuWorkspaceDoc(path: "", frontmatter: [:], body: "") },
    enqueue: { _, _, _ in "" },
    stopSession: { _ in WuhuStopSessionResponse(repairedEntries: [], stopEntry: nil) },
    setSessionModel: { _, _, _, _ in
      WuhuSetSessionModelResponse(
        session: WuhuSession(
          id: "preview",
          provider: .anthropic,
          model: "claude-sonnet-4-6",
          environment: WuhuEnvironment(name: "preview", type: .local, path: "/tmp"),
          cwd: "/tmp",
          parentSessionID: nil,
          createdAt: Date(),
          updatedAt: Date(),
          headEntryID: 0,
          tailEntryID: 0
        ),
        selection: WuhuSessionSettings(provider: .anthropic, model: "claude-sonnet-4-6"),
        applied: true
      )
    },
  )
}

extension DependencyValues {
  var apiClient: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
}

// MARK: - Session Transport Provider

struct SessionTransportProvider: Sendable {
  var make: @Sendable () -> RemoteSessionSSETransport
}

extension SessionTransportProvider: DependencyKey {
  static let liveValue: SessionTransportProvider = {
    let urlString = UserDefaults.standard.string(forKey: "wuhuServerURL") ?? "http://localhost:8080"
    let baseURL = URL(string: urlString) ?? URL(string: "http://localhost:8080")!
    return SessionTransportProvider(
      make: { RemoteSessionSSETransport(baseURL: baseURL) },
    )
  }()
}

extension SessionTransportProvider: TestDependencyKey {
  static let testValue = SessionTransportProvider(
    make: { RemoteSessionSSETransport(baseURL: URL(string: "http://localhost:8080")!) },
  )
}

extension DependencyValues {
  var sessionTransportProvider: SessionTransportProvider {
    get { self[SessionTransportProvider.self] }
    set { self[SessionTransportProvider.self] = newValue }
  }
}

// MARK: - Transcript Conversion

enum TranscriptConverter {
  static func convertTranscript(
    _ entries: [WuhuSessionEntry],
    displayStartEntryID: Int64? = nil,
  ) -> [MockMessage] {
    let visibleEntries: [WuhuSessionEntry] = if let start = displayStartEntryID {
      entries.filter { $0.id >= start }
    } else {
      entries
    }

    // Build tool result lookup from tool_execution entries
    var toolResults: [String: WuhuToolExecution] = [:]
    for entry in visibleEntries {
      if case let .toolExecution(exec) = entry.payload, exec.phase == .end {
        toolResults[exec.toolCallId] = exec
      }
    }

    var messages: [MockMessage] = []
    for entry in visibleEntries {
      guard case let .message(msg) = entry.payload else { continue }
      switch msg {
      case let .user(userMsg):
        let text = extractText(from: userMsg.content)
        guard !text.isEmpty else { continue }
        messages.append(MockMessage(
          id: "entry-\(entry.id)",
          role: .user,
          author: userMsg.user == WuhuUserMessage.unknownUser ? nil : userMsg.user,
          content: text,
          timestamp: userMsg.timestamp,
        ))

      case let .assistant(assistantMsg):
        let text = extractText(from: assistantMsg.content)
        let toolCalls = assistantMsg.content.compactMap { block -> MockToolCall? in
          guard case let .toolCall(id, name, arguments) = block else { return nil }
          let resultText: String = if let exec = toolResults[id], let result = exec.result {
            jsonValueToString(result)
          } else {
            ""
          }
          return MockToolCall(
            id: id,
            name: name,
            arguments: formatArguments(arguments),
            result: resultText,
          )
        }
        if !text.isEmpty || !toolCalls.isEmpty {
          messages.append(MockMessage(
            id: "entry-\(entry.id)",
            role: .assistant,
            content: text,
            timestamp: assistantMsg.timestamp,
            toolCalls: toolCalls,
          ))
        }

      case .toolResult, .customMessage, .unknown:
        break
      }
    }
    return messages
  }

  static func convertToChannelMessages(
    _ entries: [WuhuSessionEntry],
    displayStartEntryID: Int64? = nil,
  ) -> [MockChannelMessage] {
    let visibleEntries: [WuhuSessionEntry] = if let start = displayStartEntryID {
      entries.filter { $0.id >= start }
    } else {
      entries
    }
    var messages: [MockChannelMessage] = []
    for entry in visibleEntries {
      guard case let .message(msg) = entry.payload else { continue }
      switch msg {
      case let .user(userMsg):
        let text = extractText(from: userMsg.content)
        guard !text.isEmpty else { continue }
        messages.append(MockChannelMessage(
          id: "entry-\(entry.id)",
          author: userMsg.user == WuhuUserMessage.unknownUser ? "User" : userMsg.user,
          isAgent: false,
          content: text,
          timestamp: userMsg.timestamp,
        ))

      case let .assistant(assistantMsg):
        let text = extractText(from: assistantMsg.content)
        guard !text.isEmpty else { continue }
        messages.append(MockChannelMessage(
          id: "entry-\(entry.id)",
          author: "Wuhu Agent",
          isAgent: true,
          content: text,
          timestamp: assistantMsg.timestamp,
        ))

      case .toolResult, .customMessage, .unknown:
        break
      }
    }
    return messages
  }

  static func deriveSessionTitle(from entries: [WuhuSessionEntry]) -> String? {
    for entry in entries {
      if case let .message(.user(userMsg)) = entry.payload {
        let text = extractText(from: userMsg.content)
        if !text.isEmpty {
          return String(text.prefix(60))
        }
      }
    }
    return nil
  }

  static func sessionStatus(from response: WuhuGetSessionResponse) -> MockSession.SessionStatus {
    if let exec = response.inProcessExecution, exec.activePromptCount > 0 {
      return .running
    }
    let idleThreshold: TimeInterval = 3600
    if Date().timeIntervalSince(response.session.updatedAt) < idleThreshold {
      return .idle
    }
    return .stopped
  }

  private static func extractText(from content: [WuhuContentBlock]) -> String {
    content.compactMap { block -> String? in
      if case let .text(text, _) = block { return text }
      return nil
    }.joined()
  }

  private static func formatArguments(_ args: JSONValue) -> String {
    switch args {
    case let .string(s):
      return s
    case let .object(dict):
      if let cmd = dict["command"], case let .string(s) = cmd { return s }
      if let path = dict["file_path"], case let .string(s) = path { return s }
      if let path = dict["path"], case let .string(s) = path { return s }
      return jsonValueToString(args).prefix(100).description
    default:
      return jsonValueToString(args).prefix(100).description
    }
  }

  private static func jsonValueToString(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case let .bool(b): return String(b)
    case let .number(n): return String(n)
    case let .string(s): return s
    case let .array(arr): return "[\(arr.map { jsonValueToString($0) }.joined(separator: ", "))]"
    case let .object(dict):
      let pairs = dict.map { "\($0.key): \(jsonValueToString($0.value))" }
      return "{\(pairs.joined(separator: ", "))}"
    }
  }
}

// MARK: - Session Conversion

extension MockSession {
  static func from(_ session: WuhuSession, messages: [MockMessage] = []) -> MockSession {
    let idleThreshold: TimeInterval = 3600
    let status: SessionStatus = if Date().timeIntervalSince(session.updatedAt) < idleThreshold {
      .idle
    } else {
      .stopped
    }
    return MockSession(
      id: session.id,
      title: TranscriptConverter.deriveSessionTitle(from: []) ?? session.environment.name + " session",
      environmentName: session.environment.name,
      model: session.model,
      status: status,
      updatedAt: session.updatedAt,
      messages: messages,
    )
  }

  static func from(_ response: WuhuGetSessionResponse) -> MockSession {
    let messages = TranscriptConverter.convertTranscript(
      response.transcript,
      displayStartEntryID: response.session.displayStartEntryID,
    )
    let title = TranscriptConverter.deriveSessionTitle(from: response.transcript)
      ?? response.session.environment.name + " session"
    let status = TranscriptConverter.sessionStatus(from: response)

    return MockSession(
      id: response.session.id,
      title: title,
      environmentName: response.session.environment.name,
      model: response.session.model,
      status: status,
      updatedAt: response.session.updatedAt,
      messages: messages,
    )
  }
}

// MARK: - Channel Conversion

extension MockChannel {
  static func from(_ session: WuhuSession, messages: [MockChannelMessage] = []) -> MockChannel {
    let name = "#\(session.environment.name)"
    return MockChannel(
      id: session.id,
      name: name,
      unreadCount: 0,
      messages: messages,
    )
  }

  static func from(_ response: WuhuGetSessionResponse) -> MockChannel {
    let messages = TranscriptConverter.convertToChannelMessages(
      response.transcript,
      displayStartEntryID: response.session.displayStartEntryID,
    )
    let name = "#\(response.session.environment.name)"
    return MockChannel(
      id: response.session.id,
      name: name,
      unreadCount: 0,
      messages: messages,
    )
  }
}

// MARK: - Workspace Docs Conversion

extension MockDoc {
  static func from(_ summary: WuhuWorkspaceDocSummary) -> MockDoc {
    let title = summary.frontmatter["title"]?.stringValue
      ?? summary.path.components(separatedBy: "/").last ?? summary.path
    let tags = summary.frontmatter["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []

    return MockDoc(
      id: summary.path,
      title: title,
      tags: tags,
      updatedAt: Date(),
      markdownContent: "",
    )
  }

  static func from(_ doc: WuhuWorkspaceDoc) -> MockDoc {
    let title = doc.frontmatter["title"]?.stringValue
      ?? doc.path.components(separatedBy: "/").last ?? doc.path
    let tags = doc.frontmatter["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []

    return MockDoc(
      id: doc.path,
      title: title,
      tags: tags,
      updatedAt: Date(),
      markdownContent: doc.body,
    )
  }
}

extension MockIssue {
  static func from(_ summary: WuhuWorkspaceDocSummary) -> MockIssue? {
    guard let statusStr = summary.frontmatter["status"]?.stringValue else { return nil }

    let status: IssueStatus = switch statusStr.lowercased() {
    case "open": .open
    case "in progress", "in_progress", "inprogress": .inProgress
    case "done", "closed": .done
    default: .open
    }

    let title = summary.frontmatter["title"]?.stringValue
      ?? summary.path.components(separatedBy: "/").last ?? summary.path
    let assignee = summary.frontmatter["assignee"]?.stringValue
    let priorityStr = summary.frontmatter["priority"]?.stringValue ?? "medium"
    let priority: Priority = switch priorityStr.lowercased() {
    case "critical": .critical
    case "high": .high
    case "low": .low
    default: .medium
    }

    let description = summary.frontmatter["description"]?.stringValue ?? ""

    return MockIssue(
      id: summary.path,
      title: title,
      status: status,
      assignee: assignee,
      priority: priority,
      description: description,
    )
  }

  static func from(_ doc: WuhuWorkspaceDoc, existing: MockIssue) -> MockIssue {
    var updated = existing
    updated.markdownContent = doc.body
    return updated
  }
}

// MARK: - JSONValue Helpers

extension JSONValue {
  var stringValue: String? {
    if case let .string(s) = self { return s }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case let .array(a) = self { return a }
    return nil
  }
}
