import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import WuhuAPI
import WuhuCore

public struct WuhuServer: Sendable {
  public init() {}

  public func run(configPath: String?) async throws {
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
    let service = WuhuService(store: store)

    let envByName: [String: WuhuServerConfig.Environment] = Dictionary(uniqueKeysWithValues: config.environments.map { ($0.name, $0) })

    let router = Router(context: WuhuRequestContext.self)

    router.get("healthz") { _, _ -> String in
      "ok"
    }

    router.get("v1/sessions") { request, context async throws -> [WuhuSession] in
      struct Query: Decodable { var limit: Int? }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      return try await service.listSessions(limit: query.limit)
    }

    router.get("v1/sessions/:id") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let session = try await service.getSession(id: id)
      let transcript = try await service.getTranscript(sessionID: id)
      let response = WuhuGetSessionResponse(session: session, transcript: transcript)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions") { request, context async throws -> Response in
      let create = try await request.decode(as: WuhuCreateSessionRequest.self, context: context)

      guard let envConfig = envByName[create.environment] else {
        throw HTTPError(.badRequest, message: "Unknown environment: \(create.environment)")
      }
      guard envConfig.type == "local" else {
        throw HTTPError(.badRequest, message: "Unsupported environment type: \(envConfig.type)")
      }

      let resolvedPath = ToolPath.resolveToCwd(envConfig.path, cwd: FileManager.default.currentDirectoryPath)
      let environment = WuhuEnvironment(name: envConfig.name, type: .local, path: resolvedPath)

      let model = (create.model?.isEmpty == false) ? create.model! : defaultModel(for: create.provider)
      let systemPrompt = (create.systemPrompt?.isEmpty == false) ? create.systemPrompt! : defaultSystemPrompt

      let session = try await service.createSession(
        provider: create.provider,
        model: model,
        systemPrompt: systemPrompt,
        environment: environment,
        parentSessionID: create.parentSessionID,
      )
      return try context.responseEncoder.encode(session, from: request, context: context)
    }

    router.post("v1/sessions/:id/prompt") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let prompt = try await request.decode(as: WuhuPromptRequest.self, context: context)

      let stream = try await service.promptStream(
        sessionID: id,
        input: prompt.input,
        maxTurns: prompt.maxTurns ?? 12,
      )

      let byteStream = AsyncThrowingStream<ByteBuffer, any Error> { continuation in
        let task = Task {
          do {
            for try await event in stream {
              let apiEvent = mapPromptEvent(event)
              let data = try WuhuJSON.encoder.encode(apiEvent)
              var s = "data: "
              s += String(decoding: data, as: UTF8.self)
              s += "\n\n"
              continuation.yield(ByteBuffer(string: s))
              if case .done = apiEvent { break }
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
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

    let port = config.port ?? 5530
    let host = (config.host?.isEmpty == false) ? config.host! : "127.0.0.1"

    let app = Application(
      router: router,
      configuration: .init(address: .hostname(host, port: port)),
    )
    try await app.runService()
  }
}

private func defaultModel(for provider: WuhuProvider) -> String {
  switch provider {
  case .openai:
    "gpt-5.2-codex"
  case .anthropic:
    "claude-sonnet-4-5"
  case .openaiCodex:
    "codex-mini-latest"
  }
}

private let defaultSystemPrompt = [
  "You are a coding agent.",
  "Use tools to inspect and modify the repository in your working directory.",
  "Prefer read/grep/find/ls over guessing file contents.",
  "When making changes, use edit for surgical replacements and write for new files.",
  "Use bash to run builds/tests and gather precise outputs.",
].joined(separator: "\n")

private func ensureDirectoryExists(forDatabasePath path: String) throws {
  guard path != ":memory:" else { return }
  let url = URL(fileURLWithPath: path)
  let dir = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

private func mapPromptEvent(_ event: WuhuPromptStreamEvent) -> WuhuPromptEvent {
  switch event {
  case let .toolExecutionStart(toolCallId, toolName, args):
    .toolExecutionStart(toolCallId: toolCallId, toolName: toolName, args: args)
  case let .toolExecutionEnd(toolCallId, toolName, result, isError):
    .toolExecutionEnd(
      toolCallId: toolCallId,
      toolName: toolName,
      result: .init(
        content: result.content.map(WuhuContentBlock.fromPi),
        details: result.details,
      ),
      isError: isError,
    )
  case let .assistantTextDelta(delta):
    .assistantTextDelta(delta)
  case .done:
    .done
  }
}
