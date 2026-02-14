import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import NIOCore
import WSClient
import WSCore
import WuhuAPI
import WuhuCore

public struct WuhuServer: Sendable {
  public init() {}

  public func run(configPath: String?, llmRequestLogDir: String? = nil) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuServerConfig.defaultPath()
    let config = try WuhuServerConfig.load(path: path)

    if let openai = config.llm?.openai, !openai.isEmpty {
      setenv("OPENAI_API_KEY", openai, 1)
    }
    if let anthropic = config.llm?.anthropic, !anthropic.isEmpty {
      setenv("ANTHROPIC_API_KEY", anthropic, 1)
    }

    let dbPath: String = {
      if let p = config.databasePath, !p.isEmpty { return (p as NSString).expandingTildeInPath }
      let home = FileManager.default.homeDirectoryForCurrentUser
      return home.appendingPathComponent(".wuhu/wuhu.sqlite").path
    }()
    try ensureDirectoryExists(forDatabasePath: dbPath)

    let store = try SQLiteSessionStore(path: dbPath)

    let effectiveLogDir: String? = {
      if let llmRequestLogDir, !llmRequestLogDir.isEmpty { return llmRequestLogDir }
      if let fromConfig = config.llmRequestLogDir, !fromConfig.isEmpty { return fromConfig }
      return nil
    }()

    let requestLogger: WuhuLLMRequestLogger? = effectiveLogDir.flatMap { raw in
      let expanded = (raw as NSString).expandingTildeInPath
      return try? WuhuLLMRequestLogger(directoryURL: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    let service = WuhuService(store: store, llmRequestLogger: requestLogger)
    await service.startAgentLoopManager()

    let envByName: [String: WuhuServerConfig.Environment] = Dictionary(uniqueKeysWithValues: config.environments.map { ($0.name, $0) })
    let runnerRegistry = RunnerRegistry()

    let router = Router(context: WuhuRequestContext.self)

    router.get("healthz") { _, _ -> String in
      "ok"
    }

    router.get("v2/runners") { _, _ async -> [WuhuRunnerInfo] in
      let configured = (config.runners ?? []).map(\.name)
      let connected = await runnerRegistry.listRunnerNames()
      let connectedSet = Set(connected)
      let all = Set(configured).union(connectedSet).sorted()
      return all.map { .init(name: $0, connected: connectedSet.contains($0)) }
    }

    router.get("v2/environments") { _, _ -> [WuhuEnvironmentInfo] in
      config.environments.map { .init(name: $0.name, type: $0.type) }
    }

    router.get("v2/sessions") { request, context async throws -> [WuhuSession] in
      struct Query: Decodable { var limit: Int? }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      return try await service.listSessions(limit: query.limit)
    }

    router.get("v2/sessions/:id") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable {
        var sinceCursor: Int64?
        var sinceTime: Double?
      }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      let sinceTime = query.sinceTime.map { Date(timeIntervalSince1970: $0) }
      let session = try await service.getSession(id: id)
      let transcript: [WuhuSessionEntry] = if query.sinceCursor != nil || sinceTime != nil {
        try await service.getTranscript(sessionID: id, sinceCursor: query.sinceCursor, sinceTime: sinceTime)
      } else {
        try await service.getTranscript(sessionID: id)
      }
      let inProcessExecution = await service.inProcessExecutionInfo(sessionID: id)
      let response = WuhuGetSessionResponse(session: session, transcript: transcript, inProcessExecution: inProcessExecution)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v2/sessions") { request, context async throws -> Response in
      let create = try await request.decode(as: WuhuCreateSessionRequest.self, context: context)

      let model = (create.model?.isEmpty == false) ? create.model! : WuhuModelCatalog.defaultModelID(for: create.provider)
      let systemPrompt = (create.systemPrompt?.isEmpty == false) ? create.systemPrompt! : defaultSystemPrompt
      let sessionID = UUID().uuidString.lowercased()

      let session: WuhuSession
      if let runnerName = create.runner, !runnerName.isEmpty {
        guard let runner = await runnerRegistry.get(runnerName: runnerName) else {
          throw HTTPError(.badRequest, message: "Unknown or disconnected runner: \(runnerName)")
        }
        let environment = try await runner.resolveEnvironment(sessionID: sessionID, name: create.environment)
        session = try await service.createSession(
          sessionID: sessionID,
          provider: create.provider,
          model: model,
          reasoningEffort: create.reasoningEffort,
          systemPrompt: systemPrompt,
          environment: environment,
          runnerName: runnerName,
          parentSessionID: create.parentSessionID,
        )
        try await runner.registerSession(sessionID: session.id, environment: environment)
      } else {
        guard let envConfig = envByName[create.environment] else {
          throw HTTPError(.badRequest, message: "Unknown environment: \(create.environment)")
        }
        let environment: WuhuEnvironment
        switch envConfig.type {
        case "local":
          let resolvedPath = ToolPath.resolveToCwd(envConfig.path, cwd: FileManager.default.currentDirectoryPath)
          environment = WuhuEnvironment(name: envConfig.name, type: .local, path: resolvedPath)
        case "folder-template":
          let templatePath = ToolPath.resolveToCwd(envConfig.path, cwd: FileManager.default.currentDirectoryPath)
          let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(config.workspacesPath)
          let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
            sessionID: sessionID,
            templatePath: templatePath,
            startupScript: envConfig.startupScript,
            workspacesPath: workspacesRoot,
          )
          environment = WuhuEnvironment(
            name: envConfig.name,
            type: .folderTemplate,
            path: workspacePath,
            templatePath: templatePath,
            startupScript: envConfig.startupScript,
          )
        default:
          throw HTTPError(.badRequest, message: "Unsupported environment type: \(envConfig.type)")
        }

        session = try await service.createSession(
          sessionID: sessionID,
          provider: create.provider,
          model: model,
          reasoningEffort: create.reasoningEffort,
          systemPrompt: systemPrompt,
          environment: environment,
          runnerName: nil,
          parentSessionID: create.parentSessionID,
        )
      }
      return try context.responseEncoder.encode(session, from: request, context: context)
    }

    router.post("v2/sessions/:id/model") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let setModel = try await request.decode(as: WuhuSetSessionModelRequest.self, context: context)
      let response = try await service.setSessionModel(sessionID: id, request: setModel)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v2/sessions/:id/prompt") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let prompt = try await request.decode(as: WuhuPromptRequest.self, context: context)

      let session = try await service.getSession(id: id)

      let tools: [AnyAgentTool]? = {
        guard let runnerName = session.runnerName, !runnerName.isEmpty else { return nil }
        return WuhuRemoteTools.makeTools(
          sessionID: session.id,
          runnerName: runnerName,
          runnerRegistry: runnerRegistry,
        )
      }()

      do {
        let response = try await service.promptDetached(
          sessionID: id,
          input: prompt.input,
          user: prompt.user,
          tools: tools,
        )
        return try context.responseEncoder.encode(response, from: request, context: context)
      } catch let error as PiAIError {
        if case let .unsupported(message) = error {
          throw HTTPError(.conflict, message: message)
        }
        throw error
      }
    }

    router.post("v2/sessions/:id/stop") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let stopRequest = await (try? request.decode(as: WuhuStopSessionRequest.self, context: context)) ?? WuhuStopSessionRequest()
      let response = try await service.stopSession(sessionID: id, user: stopRequest.user)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.get("v2/sessions/:id/follow") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable {
        var sinceCursor: Int64?
        var sinceTime: Double?
        var stopAfterIdle: Int?
        var timeoutSeconds: Double?
      }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      let sinceTime = query.sinceTime.map { Date(timeIntervalSince1970: $0) }
      let stopAfterIdle = (query.stopAfterIdle ?? 0) != 0

      let stream = try await service.followSessionStream(
        sessionID: id,
        sinceCursor: query.sinceCursor,
        sinceTime: sinceTime,
        stopAfterIdle: stopAfterIdle,
        timeoutSeconds: query.timeoutSeconds,
      )

      let byteStream = AsyncStream<ByteBuffer> { continuation in
        let task = Task {
          func yieldEvent(_ apiEvent: WuhuSessionStreamEvent) {
            let data = try! WuhuJSON.encoder.encode(apiEvent)
            var s = "data: "
            s += String(decoding: data, as: UTF8.self)
            s += "\n\n"
            continuation.yield(ByteBuffer(string: s))
          }

          do {
            for try await event in stream {
              yieldEvent(event)
              if case .done = event { break }
            }
          } catch {
            yieldEvent(.assistantTextDelta("\n[error] \(error)\n"))
            yieldEvent(.done)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }

      var headers = HTTPFields()
      headers[.contentType] = "text/event-stream"
      headers[.cacheControl] = "no-cache"
      headers[.connection] = "keep-alive"

      return Response(
        status: .ok,
        headers: headers,
        body: ResponseBody(asyncSequence: byteStream),
      )
    }

    router.ws("/v2/runners/ws") { _, _ in
      .upgrade()
    } onUpgrade: { inbound, outbound, wsContext in
      do {
        try await runnerRegistry.acceptRunnerClient(inbound: inbound, outbound: outbound, logger: wsContext.logger)
      } catch {
        wsContext.logger.debug("Runner WebSocket error", metadata: ["error": "\(error)"])
      }
    }

    let port = config.port ?? 5530
    let host = (config.host?.isEmpty == false) ? config.host! : "127.0.0.1"

    let app = Application(
      router: router,
      server: .http1WebSocketUpgrade(webSocketRouter: router),
      configuration: .init(address: .hostname(host, port: port)),
    )

    if let runners = config.runners, !runners.isEmpty {
      let logger = Logger(label: "WuhuServer")
      for r in runners {
        Task {
          while !Task.isCancelled {
            do {
              try await runnerRegistry.connectToRunnerServer(runner: r, logger: logger)
            } catch {
              logger.error("Failed to connect to runner", metadata: ["runner": "\(r.name)", "error": "\(error)"])
              try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
          }
        }
      }
    }
    try await app.runService()
  }
}

private let defaultSystemPrompt = [
  "You are a coding agent.",
  "Use tools to inspect and modify the repository in your working directory.",
  "Prefer read/grep/find/ls over guessing file contents.",
  "When making changes, use edit for surgical replacements and write for new files.",
  "Use bash to run builds/tests and gather precise outputs.",
  "Use async_bash to start long-running commands in the background, and async_bash_status to check their status.",
].joined(separator: "\n")

private func ensureDirectoryExists(forDatabasePath path: String) throws {
  guard path != ":memory:" else { return }
  let url = URL(fileURLWithPath: path)
  let dir = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// Session follow streaming emits `WuhuSessionStreamEvent` directly (no mapping layer).
