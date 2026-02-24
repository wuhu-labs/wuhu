import Foundation
import PiAI
import WuhuAPI

enum WuhuAgentToolNames {
  // Coding tools (used for channel restrictions).
  static let bash = "bash"
  static let asyncBash = "async_bash"
  static let asyncBashStatus = "async_bash_status"
  static let swift = "swift"

  // Channel management tools.
  static let fork = "fork"
  static let listChildSessions = "list_child_sessions"
  static let readSessionFinalMessage = "read_session_final_message"
  static let sessionSteer = "session_steer"
  static let sessionFollowUp = "session_follow_up"
  static let envList = "env_list"
  static let envGet = "env_get"
  static let envCreate = "env_create"
  static let envUpdate = "env_update"
  static let envDelete = "env_delete"
  static let createSession = "create_session"
}

extension WuhuService {
  func agentToolset(
    session: WuhuSession,
    baseTools: [AnyAgentTool],
  ) -> [AnyAgentTool] {
    var tools = baseTools

    switch session.type {
    case .channel:
      // Management/control-plane tools are only available for channel sessions.
      tools.append(contentsOf: agentManagementTools(currentSessionID: session.id))
      // Enforce channel runtime restrictions via tool executor errors (keep schema identical).
      tools = applyChannelRestrictions(tools)

    case .forkedChannel:
      // Forked channels keep the same tool schema as the parent channel (preserving prefix cache)
      // but have coding-level execution permissions — no restrictions applied.
      tools.append(contentsOf: agentManagementTools(currentSessionID: session.id))

    case .coding:
      break
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
      case WuhuAgentToolNames.bash:
        disabled(
          tool,
          message: "Bash execution is not available in channel sessions. Use the fork tool to delegate work to a coding session.",
        )
      case WuhuAgentToolNames.asyncBash, WuhuAgentToolNames.asyncBashStatus, WuhuAgentToolNames.swift:
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
      createSessionTool(currentSessionID: currentSessionID),
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
      name: WuhuAgentToolNames.fork,
      description: "Create a child coding session inheriting this conversation history, enqueue the task, and return the new session id.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.fork) { [weak self] toolCallId, args in
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

  private func createSessionTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      var task: String
      var environmentID: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let task = try a.requireString("task")
        let environmentID = try a.requireString("environmentID")
        try a.ensureNoExtraKeys(allowed: ["task", "environmentID"])
        return .init(task: task, environmentID: environmentID)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "task": .object([
          "type": .string("string"),
          "description": .string("Task description for the new coding session"),
        ]),
        "environmentID": .object([
          "type": .string("string"),
          "description": .string("Environment UUID or name to deploy the session into"),
        ]),
      ]),
      "required": .array([.string("task"), .string("environmentID")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.createSession,
      description: "Create a fresh coding session in a specified environment with no conversation history. Use this for subagent-style dispatch where history inheritance is unwanted.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.createSession) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let task = params.task.trimmingCharacters(in: .whitespacesAndNewlines)
      let envID = params.environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !task.isEmpty else { throw WuhuToolExecutionError(message: "task must not be empty") }
      guard !envID.isEmpty else { throw WuhuToolExecutionError(message: "environmentID must not be empty") }

      let child = try await createDirectSession(
        parentSessionID: currentSessionID,
        environmentIdentifier: envID,
        task: task,
      )

      return try AgentToolResult(
        content: [.text("Created coding session: session://\(child.id)")],
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
      name: WuhuAgentToolNames.listChildSessions,
      description: "List child sessions created by this session (by parentSessionID), including status and unread final-message state.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.listChildSessions) { [weak self] _, args in
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
          "lastNotifiedFinalEntryID": record.lastNotifiedFinalEntryID.map { .string(String($0)) } ?? .null,
          "lastReadFinalEntryID": record.lastReadFinalEntryID.map { .string(String($0)) } ?? .null,
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
      name: WuhuAgentToolNames.readSessionFinalMessage,
      description: "Read the final assistant message for a session (the last assistant message without tool calls). If this session is the parent, marks it as read.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.readSessionFinalMessage) { [weak self] _, args in
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
          "entryID": .string(String(final.entryID)),
        ]),
      )
    }
  }

  private func sessionSteerTool() -> AnyAgentTool {
    sessionEnqueueTool(name: WuhuAgentToolNames.sessionSteer, lane: .steer)
  }

  private func sessionFollowUpTool() -> AnyAgentTool {
    sessionEnqueueTool(name: WuhuAgentToolNames.sessionFollowUp, lane: .followUp)
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
    let tool = Tool(name: WuhuAgentToolNames.envList, description: "List canonical environments.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.envList) { [weak self] _, args in
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
    let tool = Tool(name: WuhuAgentToolNames.envGet, description: "Get a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.envGet) { [weak self] _, args in
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
    let tool = Tool(name: WuhuAgentToolNames.envCreate, description: "Create a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.envCreate) { [weak self] _, args in
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
    let tool = Tool(name: WuhuAgentToolNames.envUpdate, description: "Update a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.envUpdate) { [weak self] _, args in
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
    let tool = Tool(name: WuhuAgentToolNames.envDelete, description: "Delete a canonical environment definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.envDelete) { [weak self] _, args in
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
    guard parent.type == .channel || parent.type == .forkedChannel else {
      throw WuhuToolExecutionError(message: "fork is only supported from channel sessions")
    }

    let settings = try await store.loadSettingsSnapshot(sessionID: .init(rawValue: parentSessionID))
    let reasoningEffort = settings.effectiveReasoningEffort

    let childSessionID = UUID().uuidString.lowercased()

    _ = try await store.createSession(
      sessionID: childSessionID,
      sessionType: .forkedChannel,
      provider: parent.provider,
      model: parent.model,
      reasoningEffort: reasoningEffort,
      systemPrompt: WuhuDefaultSystemPrompts.channelAgent,
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
      toolName: WuhuAgentToolNames.fork,
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

  private func createDirectSession(parentSessionID: String, environmentIdentifier: String, task: String) async throws -> WuhuSession {
    let parent = try await store.getSession(id: parentSessionID)
    let settings = try await store.loadSettingsSnapshot(sessionID: .init(rawValue: parentSessionID))
    let reasoningEffort = settings.effectiveReasoningEffort

    let envDef = try await store.getEnvironment(identifier: environmentIdentifier)
    let childSessionID = UUID().uuidString.lowercased()

    let environment: WuhuEnvironment
    switch envDef.type {
    case .local:
      let resolvedPath = ToolPath.resolveToCwd(envDef.path, cwd: parent.cwd)
      environment = WuhuEnvironment(name: envDef.name, type: .local, path: resolvedPath)
    case .folderTemplate:
      guard let templatePathRaw = envDef.templatePath else {
        throw WuhuToolExecutionError(message: "folder-template environment '\(envDef.name)' requires templatePath")
      }
      let templatePath = ToolPath.resolveToCwd(templatePathRaw, cwd: parent.cwd)
      let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(envDef.path)
      let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
        sessionID: childSessionID,
        templatePath: templatePath,
        startupScript: envDef.startupScript,
        workspacesPath: workspacesRoot,
      )
      environment = WuhuEnvironment(
        name: envDef.name,
        type: .folderTemplate,
        path: workspacePath,
        templatePath: templatePath,
        startupScript: envDef.startupScript,
      )
    }

    _ = try await store.createSession(
      sessionID: childSessionID,
      sessionType: .coding,
      provider: parent.provider,
      model: parent.model,
      reasoningEffort: reasoningEffort,
      systemPrompt: WuhuDefaultSystemPrompts.codingAgent,
      environmentID: envDef.id,
      environment: environment,
      runnerName: parent.runnerName,
      parentSessionID: parentSessionID,
    )

    let author: Author = .participant(.init(rawValue: "channel-agent"), kind: .bot)
    let message = QueuedUserMessage(author: author, content: .text(task))
    _ = try await enqueue(sessionID: .init(rawValue: childSessionID), message: message, lane: .followUp)

    return try await store.getSession(id: childSessionID)
  }
}
