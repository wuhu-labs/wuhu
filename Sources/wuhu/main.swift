import ArgumentParser
import Foundation
import PiAI
import WuhuAPI
import WuhuClient
import WuhuCLIKit
import WuhuRunner
import WuhuServer
import Yams

extension WuhuProvider: ExpressibleByArgument {}

@main
struct WuhuCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wuhu",
    abstract: "Wuhu (Swift) – server + client for persisted coding-agent sessions.",
    subcommands: [
      Server.self,
      Client.self,
      Runner.self,
    ],
  )

  struct Server: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "server",
      abstract: "Run the Wuhu HTTP server.",
    )

    @Option(help: "Path to server config YAML (default: ~/.wuhu/server.yml).")
    var config: String?

    func run() async throws {
      try await WuhuServer().run(configPath: config)
    }
  }

  struct Client: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "client",
      abstract: "Client commands (talk to a running Wuhu server).",
      subcommands: [
        CreateSession.self,
        Prompt.self,
        GetSession.self,
        ListSessions.self,
      ],
    )

    struct Shared: ParsableArguments {
      @Option(help: "Server base URL (default: read ~/.wuhu/client.yml, else http://127.0.0.1:5530).")
      var server: String?

      @Option(help: "Session output verbosity (full, compact, minimal).")
      var verbosity: SessionOutputVerbosity = .full
    }

    struct CreateSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "create-session",
        abstract: "Create a new persisted session.",
      )

      @Option(help: "Provider for this session.")
      var provider: WuhuProvider

      @Option(help: "Model id (server defaults depend on provider).")
      var model: String?

      @Option(help: "Environment name from server config (required).")
      var environment: String

      @Option(help: "Runner name (optional). If set, tools execute on the runner.")
      var runner: String?

      @Option(help: "System prompt override (optional).")
      var systemPrompt: String?

      @Option(help: "Parent session id (optional).")
      var parentSessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let session = try await client.createSession(.init(
          provider: provider,
          model: model,
          systemPrompt: systemPrompt,
          environment: environment,
          runner: runner,
          parentSessionID: parentSessionId,
        ))
        FileHandle.standardOutput.write(Data("\(session.id)\n".utf8))
      }
    }

    struct Prompt: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "Append a prompt to a session and stream the assistant response.",
      )

      @Option(help: "Session id returned by create-session (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @Argument(parsing: .remaining, help: "Prompt text.")
      var prompt: [String] = []

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)

        let text = prompt.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("Expected a prompt.") }

        let terminal = TerminalCapabilities()
        var printer = PromptStreamPrinter(
          style: .init(verbosity: shared.verbosity, terminal: terminal),
        )
        printer.printPromptPreamble(userText: text)

        let stream = try await client.promptStream(sessionID: sessionId, input: text)
        for try await event in stream {
          printer.handle(event)
        }
      }
    }

    struct GetSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "get-session",
        abstract: "Print session metadata and full transcript.",
      )

      @Option(help: "Session id (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let response = try await client.getSession(id: sessionId)

        let terminal = TerminalCapabilities()
        let style = SessionOutputStyle(verbosity: shared.verbosity, terminal: terminal)
        let renderer = SessionTranscriptRenderer(style: style)
        FileHandle.standardOutput.write(Data(renderer.render(response).utf8))
      }
    }

    struct ListSessions: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list-sessions",
        abstract: "List sessions.",
      )

      @Option(help: "Max sessions to list.")
      var limit: Int?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessions = try await client.listSessions(limit: limit)
        for s in sessions {
          FileHandle.standardOutput.write(Data("\(s.id)  \(s.provider.rawValue)  \(s.model)  env=\(s.environment.name)  updatedAt=\(s.updatedAt)\n".utf8))
        }
      }
    }
  }

  struct Runner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "runner",
      abstract: "Run a Wuhu runner (executes coding-agent tools remotely).",
    )

    @Option(help: "Path to runner config YAML (default: ~/.wuhu/runner.yml).")
    var config: String?

    @Option(help: "Connect to a Wuhu server (runner-as-client). Overrides config connectTo.")
    var connectTo: String?

    func run() async throws {
      try await WuhuRunner().run(configPath: config, connectTo: connectTo)
    }
  }
}

private struct WuhuClientConfig: Sendable, Codable {
  var server: String?
}

private func loadClientConfig() -> WuhuClientConfig? {
  let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".wuhu/client.yml")
    .path
  guard FileManager.default.fileExists(atPath: path) else { return nil }
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
  return try? YAMLDecoder().decode(WuhuClientConfig.self, from: text)
}

private func makeClient(_ baseOverride: String?) throws -> WuhuClient {
  let base: String = {
    if let baseOverride, !baseOverride.isEmpty { return baseOverride }
    if let cfg = loadClientConfig(), let server = cfg.server, !server.isEmpty { return server }
    return "http://127.0.0.1:5530"
  }()

  guard let url = URL(string: base) else { throw ValidationError("Invalid server URL: \(base)") }
  return WuhuClient(baseURL: url)
}

func resolveWuhuSessionId(
  _ optionValue: String?,
  env: [String: String] = ProcessInfo.processInfo.environment,
) throws -> String {
  if let optionValue {
    let trimmed = optionValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  if let envValue = env["WUHU_CURRENT_SESSION_ID"] {
    let trimmed = envValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  throw ValidationError("Missing session id. Pass --session-id or set WUHU_CURRENT_SESSION_ID.")
}
