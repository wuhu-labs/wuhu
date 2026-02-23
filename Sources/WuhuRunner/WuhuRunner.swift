import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import WSClient
import WSCore
import WuhuAPI
import WuhuCore

public struct WuhuRunner: Sendable {
  public init() {}

  public func run(configPath: String?, connectTo overrideConnectTo: String?) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuRunnerConfig.defaultPath()
    let config = try WuhuRunnerConfig.load(path: path)

    let dbPath: String = {
      if let p = config.databasePath, !p.isEmpty { return (p as NSString).expandingTildeInPath }
      let home = FileManager.default.homeDirectoryForCurrentUser
      return home.appendingPathComponent(".wuhu/runner.sqlite").path
    }()
    try ensureDirectoryExists(forDatabasePath: dbPath)

    let store = try SQLiteRunnerStore(path: dbPath)

    let connectTo = (overrideConnectTo?.isEmpty == false) ? overrideConnectTo : config.connectTo
    if let connectTo, !connectTo.isEmpty {
      try await runAsClient(runnerName: config.name, connectTo: connectTo, store: store)
      return
    }

    try await runAsServer(runnerName: config.name, config: config, store: store)
  }
}

private func runAsServer(
  runnerName: String,
  config: WuhuRunnerConfig,
  store: SQLiteRunnerStore,
) async throws {
  let router = RunnerRouter.make(runnerName: runnerName, store: store)

  let host = config.listen?.host?.isEmpty == false ? config.listen!.host! : "127.0.0.1"
  let port = config.listen?.port ?? 5531

  let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(webSocketRouter: router),
    configuration: .init(address: .hostname(host, port: port)),
  )
  try await app.runService()
}

private func runAsClient(
  runnerName: String,
  connectTo: String,
  store: SQLiteRunnerStore,
) async throws {
  let wsURL = wsURLFromHTTP(connectTo, path: "/v1/runners/ws")

  let logger = Logger(label: "WuhuRunner")
  let client = WebSocketClient(url: wsURL, logger: logger) { inbound, outbound, context in
    let hello = WuhuRunnerMessage.hello(runnerName: runnerName, version: 2)
    try await outbound.write(.text(encodeRunnerMessage(hello)))
    try await RunnerMessageLoop.handle(
      inbound: inbound,
      outbound: outbound,
      logger: context.logger,
      runnerName: runnerName,
      store: store,
    )
  }
  try await client.run()
}

private enum RunnerRouter {
  static func make(runnerName: String, store: SQLiteRunnerStore) -> Router<RunnerRequestContext> {
    let router = Router(context: RunnerRequestContext.self)

    router.get("healthz") { _, _ -> String in "ok" }

    router.ws("/v1/runner/ws") { _, _ in
      .upgrade()
    } onUpgrade: { inbound, outbound, wsContext in
      let hello = WuhuRunnerMessage.hello(runnerName: runnerName, version: 2)
      try await outbound.write(.text(encodeRunnerMessage(hello)))
      try await RunnerMessageLoop.handle(
        inbound: inbound,
        outbound: outbound,
        logger: wsContext.logger,
        runnerName: runnerName,
        store: store,
      )
    }

    return router
  }
}

private enum RunnerMessageLoop {
  static func handle(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    logger: Logger,
    runnerName _: String,
    store: SQLiteRunnerStore,
  ) async throws {
    let sender = WebSocketSender(outbound: outbound)

    for try await message in inbound.messages(maxSize: 16 * 1024 * 1024) {
      guard case let .text(text) = message else { continue }
      guard let data = text.data(using: .utf8) else { continue }

      let decoded = try WuhuJSON.decoder.decode(WuhuRunnerMessage.self, from: data)
      switch decoded {
      case .hello:
        continue

      case let .resolveEnvironmentRequest(id, sessionID, environment):
        do {
          let env = try await resolveEnvironment(environment: environment, sessionID: sessionID)
          try await sender.send(.resolveEnvironmentResponse(id: id, environment: env, error: nil))
        } catch {
          try await sender.send(.resolveEnvironmentResponse(
            id: id,
            environment: nil,
            error: String(describing: error),
          ))
        }

      case let .registerSession(sessionID, environment):
        try await store.upsertSession(sessionID: sessionID, environment: environment)

      case let .toolRequest(id, sessionID, toolCallId, toolName, args):
        Task {
          do {
            let env = try await store.getEnvironment(sessionID: sessionID)
            guard let env else {
              try await sender.send(.toolResponse(
                id: id,
                sessionID: sessionID,
                toolCallId: toolCallId,
                result: nil,
                isError: true,
                errorMessage: "Unknown session: \(sessionID)",
              ))
              return
            }

            let tools = WuhuTools.codingAgentTools(cwd: env.path)
            guard let tool = tools.first(where: { $0.tool.name == toolName }) else {
              try await sender.send(.toolResponse(
                id: id,
                sessionID: sessionID,
                toolCallId: toolCallId,
                result: nil,
                isError: true,
                errorMessage: "Unknown tool: \(toolName)",
              ))
              return
            }

            let result = try await tool.execute(toolCallId: toolCallId, args: args)
            let response = WuhuRunnerMessage.toolResponse(
              id: id,
              sessionID: sessionID,
              toolCallId: toolCallId,
              result: .init(content: result.content.map(WuhuContentBlock.fromPi), details: result.details),
              isError: false,
              errorMessage: nil,
            )
            try await sender.send(response)
          } catch {
            logger.debug("Tool execution failed", metadata: ["error": "\(error)"])
            try? await sender.send(.toolResponse(
              id: id,
              sessionID: sessionID,
              toolCallId: toolCallId,
              result: .init(content: [.text(text: String(describing: error), signature: nil)], details: .object([:])),
              isError: true,
              errorMessage: String(describing: error),
            ))
          }
        }

      case .resolveEnvironmentResponse, .toolResponse:
        continue
      }
    }
  }

  private static func resolveEnvironment(
    environment: WuhuEnvironmentDefinition,
    sessionID: String?,
  ) async throws -> WuhuEnvironment {
    switch environment.type {
    case .local:
      let resolvedPath = ToolPath.resolveToCwd(environment.path, cwd: FileManager.default.currentDirectoryPath)
      return .init(name: environment.name, type: .local, path: resolvedPath)

    case .folderTemplate:
      let effectiveSessionID = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !effectiveSessionID.isEmpty else {
        throw WuhuEnvironmentResolutionError.missingSessionIDForFolderTemplate
      }
      guard let templatePathRaw = environment.templatePath else {
        throw WuhuWorkspaceError.invalidPath("(missing templatePath)")
      }

      let templatePath = ToolPath.resolveToCwd(templatePathRaw, cwd: FileManager.default.currentDirectoryPath)
      let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(environment.path)
      let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
        sessionID: effectiveSessionID,
        templatePath: templatePath,
        startupScript: environment.startupScript,
        workspacesPath: workspacesRoot,
      )
      return .init(
        name: environment.name,
        type: .folderTemplate,
        path: workspacePath,
        templatePath: templatePath,
        startupScript: environment.startupScript,
      )
    }
  }
}

private actor WebSocketSender {
  private var outbound: WebSocketOutboundWriter

  init(outbound: WebSocketOutboundWriter) {
    self.outbound = outbound
  }

  func send(_ message: WuhuRunnerMessage) async throws {
    try await outbound.write(.text(encodeRunnerMessage(message)))
  }
}

private func encodeRunnerMessage(_ message: WuhuRunnerMessage) -> String {
  let data = try! WuhuJSON.encoder.encode(message)
  return String(decoding: data, as: UTF8.self)
}

private func wsURLFromHTTP(_ http: String, path: String) -> String {
  if http.hasPrefix("https://") {
    return "wss://" + http.dropFirst("https://".count) + path
  }
  if http.hasPrefix("http://") {
    return "ws://" + http.dropFirst("http://".count) + path
  }
  return "ws://\(http)\(path)"
}

private func ensureDirectoryExists(forDatabasePath path: String) throws {
  guard path != ":memory:" else { return }
  let url = URL(fileURLWithPath: path)
  let dir = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

private struct RunnerRequestContext: RequestContext, WebSocketRequestContext {
  var coreContext: CoreRequestContextStorage
  let webSocket: WebSocketHandlerReference<Self>

  init(source: Source) {
    coreContext = .init(source: source)
    webSocket = .init()
  }

  var requestDecoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }

  var responseEncoder: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }
}
