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
      try await runAsClient(runnerName: config.name, connectTo: connectTo, config: config, store: store)
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
  let router = RunnerRouter.make(runnerName: runnerName, config: config, store: store)

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
  config: WuhuRunnerConfig,
  store: SQLiteRunnerStore,
) async throws {
  let wsURL = wsURLFromHTTP(connectTo, path: "/v2/runners/ws")

  let logger = Logger(label: "WuhuRunner")
  let client = WebSocketClient(url: wsURL, logger: logger) { inbound, outbound, context in
    let hello = WuhuRunnerMessage.hello(runnerName: runnerName, version: 1)
    try await outbound.write(.text(encodeRunnerMessage(hello)))
    try await RunnerMessageLoop.handle(
      inbound: inbound,
      outbound: outbound,
      logger: context.logger,
      runnerName: runnerName,
      config: config,
      store: store,
    )
  }
  try await client.run()
}

private enum RunnerRouter {
  static func make(runnerName: String, config: WuhuRunnerConfig, store: SQLiteRunnerStore) -> Router<RunnerRequestContext> {
    let router = Router(context: RunnerRequestContext.self)

    router.get("healthz") { _, _ -> String in "ok" }

    router.ws("/v2/runner/ws") { _, _ in
      .upgrade()
    } onUpgrade: { inbound, outbound, wsContext in
      let hello = WuhuRunnerMessage.hello(runnerName: runnerName, version: 1)
      try await outbound.write(.text(encodeRunnerMessage(hello)))
      try await RunnerMessageLoop.handle(
        inbound: inbound,
        outbound: outbound,
        logger: wsContext.logger,
        runnerName: runnerName,
        config: config,
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
    config: WuhuRunnerConfig,
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

      case let .resolveEnvironmentRequest(id, name):
        let env = resolveEnvironment(config: config, name: name)
        let response: WuhuRunnerMessage = if let env {
          .resolveEnvironmentResponse(id: id, environment: env, error: nil)
        } else {
          .resolveEnvironmentResponse(id: id, environment: nil, error: "Unknown environment: \(name)")
        }
        try await sender.send(response)

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

  private static func resolveEnvironment(config: WuhuRunnerConfig, name: String) -> WuhuEnvironment? {
    guard let env = config.environments.first(where: { $0.name == name }) else { return nil }
    guard env.type == "local" else { return nil }
    let resolvedPath = ToolPath.resolveToCwd(env.path, cwd: FileManager.default.currentDirectoryPath)
    return .init(name: env.name, type: .local, path: resolvedPath)
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
