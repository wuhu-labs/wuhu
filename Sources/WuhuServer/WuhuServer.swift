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
    let workspaceDocsStore = WuhuWorkspaceDocsStore(
      dataRoot: URL(fileURLWithPath: dbPath, isDirectory: false).deletingLastPathComponent(),
    )
    try workspaceDocsStore.ensureDefaultDirectories()

    let effectiveLogDir: String? = {
      if let llmRequestLogDir, !llmRequestLogDir.isEmpty { return llmRequestLogDir }
      if let fromConfig = config.llmRequestLogDir, !fromConfig.isEmpty { return fromConfig }
      return nil
    }()

    let requestLogger: WuhuLLMRequestLogger? = effectiveLogDir.flatMap { raw in
      let expanded = (raw as NSString).expandingTildeInPath
      return try? WuhuLLMRequestLogger(directoryURL: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    let runnerRegistry = RunnerRegistry()

    let service = WuhuService(
      store: store,
      llmRequestLogger: requestLogger,
      remoteToolsProvider: { sessionID, runnerName in
        WuhuRemoteTools.makeTools(
          sessionID: sessionID,
          runnerName: runnerName,
          runnerRegistry: runnerRegistry,
        )
      },
    )
    await service.startAgentLoopManager()

    let router = Router(context: WuhuRequestContext.self)

    @Sendable func resolveEnvironment(_ identifier: String, missingStatus: HTTPResponse.Status) async throws -> WuhuEnvironmentDefinition {
      do {
        return try await store.getEnvironment(identifier: identifier)
      } catch let err as WuhuEnvironmentResolutionError {
        switch err {
        case .unknownEnvironment:
          throw HTTPError(missingStatus, message: err.description)
        case .unsupportedEnvironmentType, .missingSessionIDForFolderTemplate:
          throw HTTPError(.badRequest, message: err.description)
        }
      }
    }

    router.get("healthz") { _, _ -> String in
      "ok"
    }

    router.get("v1/runners") { _, _ async -> [WuhuRunnerInfo] in
      let configured = (config.runners ?? []).map(\.name)
      let connected = await runnerRegistry.listRunnerNames()
      let connectedSet = Set(connected)
      let all = Set(configured).union(connectedSet).sorted()
      return all.map { .init(name: $0, connected: connectedSet.contains($0)) }
    }

    router.get("v1/environments") { request, context async throws -> Response in
      let envs = try await store.listEnvironments()
      return try context.responseEncoder.encode(envs, from: request, context: context)
    }

    router.post("v1/environments") { request, context async throws -> Response in
      let create = try await request.decode(as: WuhuCreateEnvironmentRequest.self, context: context)
      let name = create.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = create.path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw HTTPError(.badRequest, message: "Environment name is required") }
      guard !path.isEmpty else { throw HTTPError(.badRequest, message: "Environment path is required") }

      switch create.type {
      case .local:
        if let templatePath = create.templatePath, !templatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          throw HTTPError(.badRequest, message: "local environments must not set templatePath")
        }
        if let startupScript = create.startupScript, !startupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          throw HTTPError(.badRequest, message: "local environments must not set startupScript")
        }
      case .folderTemplate:
        let templatePath = (create.templatePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templatePath.isEmpty else { throw HTTPError(.badRequest, message: "folder-template requires templatePath") }
      }

      let env = try await store.createEnvironment(create)
      return try context.responseEncoder.encode(env, from: request, context: context)
    }

    router.get("v1/environments/:identifier") { request, context async throws -> Response in
      let identifier = try context.parameters.require("identifier")
      let env = try await resolveEnvironment(identifier, missingStatus: .notFound)
      return try context.responseEncoder.encode(env, from: request, context: context)
    }

    router.get("v1/workspace/docs") { _, _ async throws -> [WuhuWorkspaceDocSummary] in
      try workspaceDocsStore.listDocs()
    }

    router.get("v1/workspace/doc") { request, context async throws -> Response in
      struct Query: Decodable { var path: String }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      do {
        let doc = try workspaceDocsStore.readDoc(relativePath: query.path)
        return try context.responseEncoder.encode(doc, from: request, context: context)
      } catch let err as WuhuWorkspaceDocsStoreError {
        switch err {
        case .notFound:
          throw HTTPError(.notFound, message: err.description)
        default:
          throw HTTPError(.badRequest, message: err.description)
        }
      }
    }

    router.patch("v1/environments/:identifier") { request, context async throws -> Response in
      let identifier = try context.parameters.require("identifier")
      let update = try await request.decode(as: WuhuUpdateEnvironmentRequest.self, context: context)
      let existing = try await resolveEnvironment(identifier, missingStatus: .notFound)

      let candidateType = update.type ?? existing.type
      let candidatePath = (update.path ?? existing.path).trimmingCharacters(in: .whitespacesAndNewlines)
      let candidateTemplatePath: String? = {
        if let v = update.templatePath { return v }
        return existing.templatePath
      }()
      let candidateStartupScript: String? = {
        if let v = update.startupScript { return v }
        return existing.startupScript
      }()

      guard !candidatePath.isEmpty else { throw HTTPError(.badRequest, message: "Environment path is required") }

      switch candidateType {
      case .local:
        if let templatePath = candidateTemplatePath, !templatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          throw HTTPError(.badRequest, message: "local environments must not set templatePath")
        }
        if let startupScript = candidateStartupScript, !startupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          throw HTTPError(.badRequest, message: "local environments must not set startupScript")
        }
      case .folderTemplate:
        let templatePath = (candidateTemplatePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templatePath.isEmpty else { throw HTTPError(.badRequest, message: "folder-template requires templatePath") }
      }

      let env = try await store.updateEnvironment(identifier: identifier, request: update)
      return try context.responseEncoder.encode(env, from: request, context: context)
    }

    router.delete("v1/environments/:identifier") { _, context async throws -> Response in
      let identifier = try context.parameters.require("identifier")
      do {
        try await store.deleteEnvironment(identifier: identifier)
      } catch let err as WuhuEnvironmentResolutionError {
        switch err {
        case .unknownEnvironment:
          throw HTTPError(.notFound, message: err.description)
        case .unsupportedEnvironmentType, .missingSessionIDForFolderTemplate:
          throw HTTPError(.badRequest, message: err.description)
        }
      }
      return Response(status: .noContent)
    }

    router.get("v1/sessions") { request, context async throws -> [WuhuSession] in
      struct Query: Decodable { var limit: Int? }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      return try await service.listSessions(limit: query.limit)
    }

    router.get("v1/sessions/:id") { request, context async throws -> Response in
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

    router.post("v1/sessions") { request, context async throws -> Response in
      let create = try await request.decode(as: WuhuCreateSessionRequest.self, context: context)

      let sessionType = create.type ?? .coding
      let model = (create.model?.isEmpty == false) ? create.model! : WuhuModelCatalog.defaultModelID(for: create.provider)
      let systemPrompt: String = if let prompt = create.systemPrompt, !prompt.isEmpty {
        prompt
      } else {
        switch sessionType {
        case .coding:
          WuhuDefaultSystemPrompts.codingAgent
        case .channel:
          WuhuDefaultSystemPrompts.channelAgent
        case .forkedChannel:
          WuhuDefaultSystemPrompts.forkedChannelAgent
        }
      }
      let sessionID = UUID().uuidString.lowercased()

      let session: WuhuSession
      if let runnerName = create.runner, !runnerName.isEmpty {
        if let directPath = create.environmentPath, !directPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          throw HTTPError(.badRequest, message: "environmentPath is not supported for runner sessions")
        }

        let envIdentifier = (create.environment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !envIdentifier.isEmpty else { throw HTTPError(.badRequest, message: "Environment identifier is required") }
        let environmentDefinition = try await resolveEnvironment(envIdentifier, missingStatus: .badRequest)

        guard let runner = await runnerRegistry.get(runnerName: runnerName) else {
          throw HTTPError(.badRequest, message: "Unknown or disconnected runner: \(runnerName)")
        }
        let environment = try await runner.resolveEnvironment(sessionID: sessionID, environment: environmentDefinition)
        session = try await service.createSession(
          sessionID: sessionID,
          sessionType: sessionType,
          provider: create.provider,
          model: model,
          reasoningEffort: create.reasoningEffort,
          systemPrompt: systemPrompt,
          environmentID: environmentDefinition.id,
          environment: environment,
          runnerName: runnerName,
          parentSessionID: create.parentSessionID,
        )
        try await runner.registerSession(sessionID: session.id, environment: environment)
      } else {
        let environment: WuhuEnvironment
        var environmentID: String?

        if let directPath = create.environmentPath, !directPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let resolvedPath = ToolPath.resolveToCwd(directPath, cwd: FileManager.default.currentDirectoryPath)
          let candidate = URL(fileURLWithPath: resolvedPath).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
          let name = candidate.isEmpty ? "workspace" : candidate
          environment = WuhuEnvironment(name: name, type: .local, path: resolvedPath)
          environmentID = nil
        } else {
          let envIdentifier = (create.environment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          guard !envIdentifier.isEmpty else { throw HTTPError(.badRequest, message: "Environment identifier is required") }
          let environmentDefinition = try await resolveEnvironment(envIdentifier, missingStatus: .badRequest)
          environmentID = environmentDefinition.id

          switch environmentDefinition.type {
          case .local:
            let resolvedPath = ToolPath.resolveToCwd(environmentDefinition.path, cwd: FileManager.default.currentDirectoryPath)
            environment = WuhuEnvironment(name: environmentDefinition.name, type: .local, path: resolvedPath)
          case .folderTemplate:
            guard let templatePathRaw = environmentDefinition.templatePath else {
              throw HTTPError(.badRequest, message: "folder-template requires templatePath")
            }
            let templatePath = ToolPath.resolveToCwd(templatePathRaw, cwd: FileManager.default.currentDirectoryPath)
            let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(environmentDefinition.path)
            let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
              sessionID: sessionID,
              templatePath: templatePath,
              startupScript: environmentDefinition.startupScript,
              workspacesPath: workspacesRoot,
            )
            environment = WuhuEnvironment(
              name: environmentDefinition.name,
              type: .folderTemplate,
              path: workspacePath,
              templatePath: templatePath,
              startupScript: environmentDefinition.startupScript,
            )
          }
        }

        session = try await service.createSession(
          sessionID: sessionID,
          sessionType: sessionType,
          provider: create.provider,
          model: model,
          reasoningEffort: create.reasoningEffort,
          systemPrompt: systemPrompt,
          environmentID: environmentID,
          environment: environment,
          runnerName: nil,
          parentSessionID: create.parentSessionID,
        )
      }
      return try context.responseEncoder.encode(session, from: request, context: context)
    }

    router.patch("v1/sessions/:id") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let rename = try await request.decode(as: WuhuRenameSessionRequest.self, context: context)
      let session = try await service.renameSession(sessionID: id, title: rename.title)
      let response = WuhuRenameSessionResponse(session: session)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions/:id/model") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let setModel = try await request.decode(as: WuhuSetSessionModelRequest.self, context: context)
      let response = try await service.setSessionModel(sessionID: id, request: setModel)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions/:id/stop") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let stopRequest = await (try? request.decode(as: WuhuStopSessionRequest.self, context: context)) ?? WuhuStopSessionRequest()
      let response = try await service.stopSession(sessionID: id, user: stopRequest.user)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.get("v1/sessions/:id/follow") { request, context async throws -> Response in
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

    // MARK: - Session contracts (commands + subscription)

    router.post("v1/sessions/:id/enqueue") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable { var lane: String }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      guard let lane = UserQueueLane(rawValue: query.lane) else {
        throw HTTPError(.badRequest, message: "Invalid lane: \(query.lane)")
      }

      let message = try await request.decode(as: QueuedUserMessage.self, context: context)
      let qid = try await service.enqueue(sessionID: .init(rawValue: id), message: message, lane: lane)
      return try context.responseEncoder.encode(qid, from: request, context: context)
    }

    router.post("v1/sessions/:id/cancel") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable { var lane: String }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      guard let lane = UserQueueLane(rawValue: query.lane) else {
        throw HTTPError(.badRequest, message: "Invalid lane: \(query.lane)")
      }

      struct Body: Decodable { var id: QueueItemID }
      let body = try await request.decode(as: Body.self, context: context)
      try await service.cancel(sessionID: .init(rawValue: id), id: body.id, lane: lane)

      return Response(status: .ok)
    }

    router.get("v1/sessions/:id/subscribe") { request, context async throws -> Response in
      let id = try context.parameters.require("id")

      struct Query: Decodable {
        var transcriptSince: String?
        var transcriptPageSize: Int?
        var systemSince: String?
        var steerSince: String?
        var followUpSince: String?
      }

      let query = try request.uri.decodeQuery(as: Query.self, context: context)

      let subRequest = SessionSubscriptionRequest(
        transcriptSince: query.transcriptSince.flatMap { $0.isEmpty ? nil : TranscriptCursor(rawValue: $0) },
        transcriptPageSize: query.transcriptPageSize ?? 200,
        systemSince: query.systemSince.flatMap { $0.isEmpty ? nil : QueueCursor(rawValue: $0) },
        steerSince: query.steerSince.flatMap { $0.isEmpty ? nil : QueueCursor(rawValue: $0) },
        followUpSince: query.followUpSince.flatMap { $0.isEmpty ? nil : QueueCursor(rawValue: $0) },
      )

      let subscription = try await service.subscribe(sessionID: .init(rawValue: id), since: subRequest)

      let byteStream = AsyncStream<ByteBuffer> { continuation in
        let task = Task {
          func yieldFrame(_ frame: SessionSubscriptionSSEFrame) -> Bool {
            guard let data = try? WuhuJSON.encoder.encode(frame) else { return false }
            var s = "data: "
            s += String(decoding: data, as: UTF8.self)
            s += "\n\n"
            continuation.yield(ByteBuffer(string: s))
            return true
          }

          guard yieldFrame(.initial(subscription.initial)) else {
            continuation.finish()
            return
          }

          do {
            for try await event in subscription.events {
              if !yieldFrame(.event(event)) {
                break
              }
            }
          } catch {
            // Best-effort: close stream. Clients retry.
          }

          continuation.finish()
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
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

    router.ws("/v1/runners/ws") { _, _ in
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

private func ensureDirectoryExists(forDatabasePath path: String) throws {
  guard path != ":memory:" else { return }
  let url = URL(fileURLWithPath: path)
  let dir = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// Session follow streaming emits `WuhuSessionStreamEvent` directly (no mapping layer).
