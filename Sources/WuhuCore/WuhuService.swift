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
      onIdle: { [weak self] idleSessionID in
        guard let self else { return }
        await handleSessionIdle(sessionID: idleSessionID)
      },
    )
    runtimes[sessionID] = runtime
    return runtime
  }

  private func enqueueSystemJSON(sessionID: String, jsonText: String, timestamp: Date) async throws {
    let input = SystemUrgentInput(source: .asyncBashCallback, content: .text(jsonText))
    try await runtime(for: sessionID).enqueueSystem(input: input, enqueuedAt: timestamp)
  }

  private func handleSessionIdle(sessionID: String) async {
    guard let childSession = try? await store.getSession(id: sessionID) else { return }
    guard let parentSessionID = childSession.parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !parentSessionID.isEmpty
    else { return }

    guard let parentSession = try? await store.getSession(id: parentSessionID) else { return }
    guard parentSession.type == .channel else { return }

    guard let final = try? await loadFinalAssistantMessage(sessionID: sessionID) else { return }

    let didUpdate = await (try? store.setChildFinalMessageNotified(
      parentSessionID: parentSessionID,
      childSessionID: sessionID,
      finalEntryID: final.entryID,
    )) ?? false
    guard didUpdate else { return }

    let text = [
      "Child session is idle: session://\(sessionID)",
      "",
      "Final message:",
      final.text,
    ].joined(separator: "\n")
    let input = SystemUrgentInput(source: .asyncTaskNotification, content: .text(text))
    try? await runtime(for: parentSessionID).enqueueSystem(input: input, enqueuedAt: Date())
  }

  private func loadFinalAssistantMessage(sessionID: String) async throws -> (entryID: Int64, text: String) {
    let transcript = try await store.getEntries(sessionID: sessionID)

    for entry in transcript.reversed() {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .assistant(a) = m else { continue }

      let hasToolCalls = a.content.contains { block in
        if case .toolCall = block { return true }
        return false
      }
      if hasToolCalls { continue }

      let text = a.content.compactMap { block -> String? in
        if case let .text(text: text, signature: _) = block { return text }
        return nil
      }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

      return (entryID: entry.id, text: text.isEmpty ? "(no text)" : text)
    }

    throw PiAIError.unsupported("No final assistant message found for session '\(sessionID)'")
  }

  private func agentToolset(
    session: WuhuSession,
    baseTools: [AnyAgentTool],
  ) -> [AnyAgentTool] {
    var tools = baseTools

    // Ensure the management/control-plane tools exist for both coding and channel sessions.
    tools.append(contentsOf: agentManagementTools(currentSessionID: session.id))

    // Enforce channel runtime restrictions via tool executor errors (keep schema identical).
    if session.type == .channel {
      tools = applyChannelRestrictions(tools)
    }

    return tools
  }

  private func applyChannelRestrictions(_ tools: [AnyAgentTool]) -> [AnyAgentTool] {
    func disabled(_ tool: AnyAgentTool, message: String) -> AnyAgentTool {
      AnyAgentTool(tool: tool.tool, label: tool.label) { _, _ in
        throw WuhuToolExecutionError(message: message)
      }
    }

    return tools.map { tool in
      switch tool.tool.name {
      case "bash":
        disabled(
          tool,
          message: "Bash execution is not available in channel sessions. Use the fork tool to delegate work to a coding session.",
        )
      case "async_bash", "async_bash_status", "swift":
        disabled(
          tool,
          message: "Command execution is not available in channel sessions. Use the fork tool to delegate work to a coding session.",
        )
      default:
        tool
      }
    }
  }

  private func agentManagementTools(currentSessionID: String) -> [AnyAgentTool] {
    [
      forkTool(currentSessionID: currentSessionID),
      listChildSessionsTool(currentSessionID: currentSessionID),
      readSessionFinalMessageTool(currentSessionID: currentSessionID),
      sessionSteerTool(),
      sessionFollowUpTool(),
      envListTool(),
      envGetTool(),
      envCreateTool(),
      envUpdateTool(),
      envDeleteTool(),
    ]
  }

  private func forkTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      var task: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let task = try a.requireString("task")
        try a.ensureNoExtraKeys(allowed: ["task"])
        return .init(task: task)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "task": .object([
          "type": .string("string"),
          "description": .string("Task description for the child coding session"),
        ]),
      ]),
      "required": .array([.string("task")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: "fork",
      description: "Create a child coding session inheriting this conversation history, enqueue the task, and return the new session id.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: "fork") { [weak self] toolCallId, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let task = params.task.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !task.isEmpty else { throw WuhuToolExecutionError(message: "fork task must not be empty") }

      let child = try await forkCodingSession(
        parentSessionID: currentSessionID,
        toolCallId: toolCallId,
        task: task,
      )

      return try AgentToolResult(
        content: [.text("Forked coding session: session://\(child.id)")],
        details: .object([
          "sessionID": .string(child.id),
          "session": WuhuJSON.encoder.encodeToJSONValue(child),
        ]),
      )
    }
  }

  private func listChildSessionsTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        try a.ensureNoExtraKeys(allowed: [])
        return .init()
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: "list_child_sessions",
      description: "List child sessions created by this session (by parentSessionID), including status and unread final-message state.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: "list_child_sessions") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      _ = try Params.parse(toolName: tool.name, args: args)

      let children = try await store.listChildSessions(parentSessionID: currentSessionID)

      let lines = children.map { record in
        let unread = record.hasUnreadFinalMessage ? "unread" : "read"
        return "\(record.session.type.rawValue) \(record.session.id) [\(record.executionStatus.rawValue)] \(unread)"
      }

      let sessionsJSON: [JSONValue] = children.map { record in
        .object([
          "id": .string(record.session.id),
          "type": .string(record.session.type.rawValue),
          "status": .string(record.executionStatus.rawValue),
          "hasUnreadFinalMessage": .bool(record.hasUnreadFinalMessage),
          "lastNotifiedFinalEntryID": record.lastNotifiedFinalEntryID.map { .number(Double($0)) } ?? .null,
          "lastReadFinalEntryID": record.lastReadFinalEntryID.map { .number(Double($0)) } ?? .null,
        ])
      }

      return AgentToolResult(
        content: [.text(lines.isEmpty ? "(no child sessions)" : lines.joined(separator: "\n"))],
        details: .object(["sessions": .array(sessionsJSON)]),
      )
    }
  }

  private func readSessionFinalMessageTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      var sessionID: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let sessionID = try a.requireString("sessionID")
        try a.ensureNoExtraKeys(allowed: ["sessionID"])
        return .init(sessionID: sessionID)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "sessionID": .object([
          "type": .string("string"),
          "description": .string("Child session id (or any session id)"),
        ]),
      ]),
      "required": .array([.string("sessionID")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: "read_session_final_message",
      description: "Read the final assistant message for a session (the last assistant message without tool calls). If this session is the parent, marks it as read.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: "read_session_final_message") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let targetID = params.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !targetID.isEmpty else { throw WuhuToolExecutionError(message: "sessionID is required") }

      let final = try await loadFinalAssistantMessage(sessionID: targetID)
      if let session = try? await store.getSession(id: targetID),
         session.parentSessionID == currentSessionID
      {
        try? await store.markChildFinalMessageRead(parentSessionID: currentSessionID, childSessionID: targetID, finalEntryID: final.entryID)
      }

      return AgentToolResult(
        content: [.text(final.text)],
        details: .object([
          "sessionID": .string(targetID),
          "entryID": .number(Double(final.entryID)),
        ]),
      )
    }
  }

  private func sessionSteerTool() -> AnyAgentTool {
    sessionEnqueueTool(name: "session_steer", lane: .steer)
  }

  private func sessionFollowUpTool() -> AnyAgentTool {
    sessionEnqueueTool(name: "session_follow_up", lane: .followUp)
  }

  private func sessionEnqueueTool(name: String, lane: UserQueueLane) -> AnyAgentTool {
    struct Params: Sendable {
      var sessionID: String
      var message: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let sessionID = try a.requireString("sessionID")
        let message = try a.requireString("message")
        try a.ensureNoExtraKeys(allowed: ["sessionID", "message"])
        return .init(sessionID: sessionID, message: message)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "sessionID": .object(["type": .string("string"), "description": .string("Target session id")]),
        "message": .object(["type": .string("string"), "description": .string("Message text to inject")]),
      ]),
      "required": .array([.string("sessionID"), .string("message")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: name,
      description: "Inject a message into a session via the \(lane.rawValue) lane.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: name) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let targetID = params.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = params.message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !targetID.isEmpty else { throw WuhuToolExecutionError(message: "sessionID is required") }
      guard !text.isEmpty else { throw WuhuToolExecutionError(message: "message is required") }

      let author: Author = .participant(.init(rawValue: "channel-agent"), kind: .bot)
      let message = QueuedUserMessage(author: author, content: .text(text))
      let qid = try await enqueue(sessionID: .init(rawValue: targetID), message: message, lane: lane)

      return AgentToolResult(
        content: [.text("enqueued \(lane.rawValue) id=\(qid.rawValue)")],
        details: .object(["queueID": .string(qid.rawValue)]),
      )
    }
  }

  private func envListTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: "env_list", description: "List canonical environments.", parameters: schema)

    return AnyAgentTool(tool: tool, label: "env_list") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      try a.ensureNoExtraKeys(allowed: [])

      let envs = try await store.listEnvironments()
      let lines = envs.map { "\($0.name) (\($0.type.rawValue)) id=\($0.id)" }
      let json: [JSONValue] = envs.map { env in
        (try? WuhuJSON.encoder.encodeToJSONValue(env)) ?? .null
      }
      return AgentToolResult(
        content: [.text(lines.isEmpty ? "(no environments)" : lines.joined(separator: "\n"))],
        details: .object(["environments": .array(json)]),
      )
    }
  }

  private func envGetTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "identifier": .object(["type": .string("string"), "description": .string("Environment UUID or unique name")]),
      ]),
      "required": .array([.string("identifier")]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: "env_get", description: "Get a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: "env_get") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      let identifier = try a.requireString("identifier").trimmingCharacters(in: .whitespacesAndNewlines)
      try a.ensureNoExtraKeys(allowed: ["identifier"])
      guard !identifier.isEmpty else { throw WuhuToolExecutionError(message: "identifier is required") }

      let env = try await store.getEnvironment(identifier: identifier)
      return try AgentToolResult(
        content: [.text("\(env.name) (\(env.type.rawValue)) id=\(env.id)\npath=\(env.path)")],
        details: WuhuJSON.encoder.encodeToJSONValue(env),
      )
    }
  }

  private func envCreateTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "name": .object(["type": .string("string")]),
        "type": .object(["type": .string("string"), "description": .string("local or folder-template")]),
        "path": .object(["type": .string("string")]),
        "templatePath": .object(["type": .string("string")]),
        "startupScript": .object(["type": .string("string")]),
      ]),
      "required": .array([.string("name"), .string("type"), .string("path")]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: "env_create", description: "Create a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: "env_create") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      let name = try a.requireString("name").trimmingCharacters(in: .whitespacesAndNewlines)
      let typeRaw = try a.requireString("type").trimmingCharacters(in: .whitespacesAndNewlines)
      let path = try a.requireString("path").trimmingCharacters(in: .whitespacesAndNewlines)
      let templatePath = try a.optionalString("templatePath")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let startupScript = try a.optionalString("startupScript")?.trimmingCharacters(in: .whitespacesAndNewlines)
      try a.ensureNoExtraKeys(allowed: ["name", "type", "path", "templatePath", "startupScript"])

      guard !name.isEmpty else { throw WuhuToolExecutionError(message: "name is required") }
      guard !path.isEmpty else { throw WuhuToolExecutionError(message: "path is required") }
      guard let type = WuhuEnvironmentType(rawValue: typeRaw) else {
        throw WuhuToolExecutionError(message: "Invalid environment type: \(typeRaw)")
      }

      switch type {
      case .local:
        if let templatePath, !templatePath.isEmpty { throw WuhuToolExecutionError(message: "local environments must not set templatePath") }
        if let startupScript, !startupScript.isEmpty { throw WuhuToolExecutionError(message: "local environments must not set startupScript") }
      case .folderTemplate:
        let t = (templatePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw WuhuToolExecutionError(message: "folder-template requires templatePath") }
      }

      let env = try await store.createEnvironment(.init(
        name: name,
        type: type,
        path: path,
        templatePath: (templatePath?.isEmpty == false) ? templatePath : nil,
        startupScript: (startupScript?.isEmpty == false) ? startupScript : nil,
      ))

      return try AgentToolResult(
        content: [.text("created env \(env.name) id=\(env.id)")],
        details: WuhuJSON.encoder.encodeToJSONValue(env),
      )
    }
  }

  private func envUpdateTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "identifier": .object(["type": .string("string")]),
        "name": .object(["type": .string("string")]),
        "type": .object(["type": .string("string"), "description": .string("local or folder-template")]),
        "path": .object(["type": .string("string")]),
        "templatePath": .object(["type": .string("string")]),
        "startupScript": .object(["type": .string("string")]),
        "clearTemplatePath": .object(["type": .string("boolean")]),
        "clearStartupScript": .object(["type": .string("boolean")]),
      ]),
      "required": .array([.string("identifier")]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: "env_update", description: "Update a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: "env_update") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      let identifier = try a.requireString("identifier").trimmingCharacters(in: .whitespacesAndNewlines)
      let name = try a.optionalString("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let typeRaw = try a.optionalString("type")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = try a.optionalString("path")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let templatePathStr = try a.optionalString("templatePath")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let startupScriptStr = try a.optionalString("startupScript")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let clearTemplatePath = try (a.optionalBool("clearTemplatePath")) ?? false
      let clearStartupScript = try (a.optionalBool("clearStartupScript")) ?? false
      try a.ensureNoExtraKeys(allowed: ["identifier", "name", "type", "path", "templatePath", "startupScript", "clearTemplatePath", "clearStartupScript"])

      guard !identifier.isEmpty else { throw WuhuToolExecutionError(message: "identifier is required") }

      let type = typeRaw.flatMap(WuhuEnvironmentType.init(rawValue:))
      if typeRaw != nil, type == nil {
        throw WuhuToolExecutionError(message: "Invalid environment type: \(typeRaw!)")
      }

      let templatePath: String?? = if clearTemplatePath {
        .some(nil)
      } else if let templatePathStr {
        .some(templatePathStr.isEmpty ? nil : templatePathStr)
      } else {
        nil
      }

      let startupScript: String?? = if clearStartupScript {
        .some(nil)
      } else if let startupScriptStr {
        .some(startupScriptStr.isEmpty ? nil : startupScriptStr)
      } else {
        nil
      }

      let update = WuhuUpdateEnvironmentRequest(
        name: name?.isEmpty == false ? name : nil,
        type: type,
        path: path?.isEmpty == false ? path : nil,
        templatePath: templatePath,
        startupScript: startupScript,
      )

      let env = try await store.updateEnvironment(identifier: identifier, request: update)
      return try AgentToolResult(
        content: [.text("updated env \(env.name) id=\(env.id)")],
        details: WuhuJSON.encoder.encodeToJSONValue(env),
      )
    }
  }

  private func envDeleteTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "identifier": .object(["type": .string("string")]),
      ]),
      "required": .array([.string("identifier")]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: "env_delete", description: "Delete a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: "env_delete") { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      let identifier = try a.requireString("identifier").trimmingCharacters(in: .whitespacesAndNewlines)
      try a.ensureNoExtraKeys(allowed: ["identifier"])
      guard !identifier.isEmpty else { throw WuhuToolExecutionError(message: "identifier is required") }

      try await store.deleteEnvironment(identifier: identifier)
      return AgentToolResult(content: [.text("deleted env \(identifier)")], details: .object([:]))
    }
  }

  private func forkCodingSession(parentSessionID: String, toolCallId: String, task: String) async throws -> WuhuSession {
    let parent = try await store.getSession(id: parentSessionID)
    guard parent.type == .channel else {
      throw WuhuToolExecutionError(message: "fork is only supported from channel sessions")
    }

    let settings = try await store.loadSettingsSnapshot(sessionID: .init(rawValue: parentSessionID))
    let reasoningEffort = settings.effectiveReasoningEffort

    let childSessionID = UUID().uuidString.lowercased()

    _ = try await store.createSession(
      sessionID: childSessionID,
      sessionType: .coding,
      provider: parent.provider,
      model: parent.model,
      reasoningEffort: reasoningEffort,
      systemPrompt: WuhuDefaultSystemPrompts.codingAgent,
      environmentID: parent.environmentID,
      environment: parent.environment,
      runnerName: parent.runnerName,
      parentSessionID: parentSessionID,
    )

    let parentTranscript = try await store.getEntries(sessionID: parentSessionID)
    let cutoff = parentTranscript.lastIndex { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .assistant(a) = m else { return false }
      return a.content.contains { block in
        guard case let .toolCall(id: id, name: _, arguments: _) = block else { return false }
        return id == toolCallId
      }
    } ?? (parentTranscript.count - 1)

    if cutoff >= 0 {
      for entry in parentTranscript[0 ... cutoff] {
        guard case let .message(m) = entry.payload else { continue }
        _ = try await store.appendEntryWithSession(
          sessionID: .init(rawValue: childSessionID),
          payload: .message(m),
          createdAt: entry.createdAt,
        )
      }
    }

    let forkResult = AgentToolResult(
      content: [.text("Forked coding session: session://\(childSessionID)")],
      details: .object(["sessionID": .string(childSessionID)]),
    )
    let now = Date()
    let toolResultMessage: Message = .toolResult(.init(
      toolCallId: toolCallId,
      toolName: "fork",
      content: forkResult.content,
      details: forkResult.details,
      isError: false,
      timestamp: now,
    ))
    _ = try await store.appendEntryWithSession(
      sessionID: .init(rawValue: childSessionID),
      payload: .message(.fromPi(toolResultMessage)),
      createdAt: now,
    )

    let forkPoint = try await store.appendEntry(
      sessionID: childSessionID,
      payload: .custom(
        customType: "wuhu_fork_point_v1",
        data: .object([
          "parentSessionID": .string(parentSessionID),
          "childSessionID": .string(childSessionID),
          "task": .string(task),
        ]),
      ),
    )
    try await store.setDisplayStartEntryID(sessionID: childSessionID, entryID: forkPoint.id)

    // Ensure copied history doesn't leave the child marked running before we enqueue the task.
    try await store.setSessionExecutionStatus(sessionID: .init(rawValue: childSessionID), status: .idle)

    let author: Author = .participant(.init(rawValue: "channel-agent"), kind: .bot)
    let message = QueuedUserMessage(author: author, content: .text(task))
    _ = try await enqueue(sessionID: .init(rawValue: childSessionID), message: message, lane: .followUp)

    return try await store.getSession(id: childSessionID)
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
    sessionType: WuhuSessionType = .coding,
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
      sessionType: sessionType,
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

    let baseTools: [AnyAgentTool]
    if let runnerName = session.runnerName, !runnerName.isEmpty {
      if let remoteToolsProvider {
        baseTools = try await remoteToolsProvider(sessionID.rawValue, runnerName)
      } else {
        // Remote sessions require a server-provided tool executor; fail loudly.
        throw PiAIError.unsupported("Session '\(sessionID.rawValue)' uses runner '\(runnerName)', but no remoteToolsProvider is configured")
      }
    } else {
      let asyncBash = WuhuAsyncBashToolContext(registry: asyncBashRegistry, sessionID: sessionID.rawValue, ownerID: instanceID)
      baseTools = WuhuTools.codingAgentTools(
        cwd: session.cwd,
        asyncBash: asyncBash,
      )
    }

    let resolvedTools = agentToolset(session: session, baseTools: baseTools)

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
