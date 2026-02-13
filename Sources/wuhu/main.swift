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
extension ReasoningEffort: ExpressibleByArgument {}

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

    @Option(help: "If set, dump all LLM requests/responses to this directory (JSON, ordered by time).")
    var llmRequestLogDir: String?

    func run() async throws {
      try await WuhuServer().run(configPath: config, llmRequestLogDir: llmRequestLogDir)
    }
  }

  struct Client: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "client",
      abstract: "Client commands (talk to a running Wuhu server).",
      subcommands: [
        CreateSession.self,
        SetModel.self,
        Prompt.self,
        StopSession.self,
        GetSession.self,
        ListSessions.self,
      ],
    )

    struct Shared: ParsableArguments {
      @Option(help: "Server base URL (default: read ~/.wuhu/client.yml, else http://127.0.0.1:5530).")
      var server: String?

      @Option(help: "Username for prompts (default: WUHU_USERNAME, else ~/.wuhu/client.yml username, else <osuser>@<hostname>).")
      var username: String?

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

      @Option(help: "Reasoning effort (minimal, low, medium, high, xhigh). Only applies to some OpenAI/Codex models.")
      var reasoningEffort: ReasoningEffort?

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
          reasoningEffort: reasoningEffort,
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

      @Flag(help: "Send the prompt and return immediately (do not wait for the agent to finish).")
      var detach: Bool = false

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let username = resolveWuhuUsername(shared.username)

        let text = prompt.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("Expected a prompt.") }

        let terminal = TerminalCapabilities()
        var printer = SessionStreamPrinter(
          style: .init(verbosity: shared.verbosity, terminal: terminal),
        )

        if detach {
          let response = try await client.promptDetached(sessionID: sessionId, input: text, user: username)
          printer.printEntryIfVisible(response.userEntry)
          return
        }

        let stream = try await client.promptStream(sessionID: sessionId, input: text, user: username)
        for try await event in stream {
          printer.handle(event)
        }
      }
    }

    struct SetModel: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "set-model",
        abstract: "Change the model selection for an existing session.",
      )

      @Option(help: "Session id returned by create-session (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @Option(help: "Provider for this session.")
      var provider: WuhuProvider

      @Option(help: "Model id (server defaults depend on provider).")
      var model: String?

      @Option(help: "Reasoning effort (minimal, low, medium, high, xhigh). Only applies to some OpenAI/Codex models.")
      var reasoningEffort: ReasoningEffort?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let response = try await client.setSessionModel(
          sessionID: sessionId,
          provider: provider,
          model: model,
          reasoningEffort: reasoningEffort,
        )

        let effort = response.selection.reasoningEffort?.rawValue ?? "default"
        let status = response.applied ? "applied" : "pending"
        FileHandle.standardOutput.write(
          Data("\(status)  \(response.selection.provider.rawValue)  \(response.selection.model)  reasoning=\(effort)\n".utf8),
        )
      }
    }

    struct StopSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "stop-session",
        abstract: "Stop the current session execution, if any.",
      )

      @Option(help: "Session id (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let username = resolveWuhuUsername(shared.username)

        let response = try await client.stopSession(sessionID: sessionId, user: username)
        if let stopEntry = response.stopEntry {
          FileHandle.standardOutput.write(
            Data("stopped  cursor=\(stopEntry.id)  repaired=\(response.repairedEntries.count)\n".utf8),
          )
        } else {
          FileHandle.standardOutput.write(Data("idle\n".utf8))
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

      @Option(help: "Only include transcript entries after this cursor id (exclusive).")
      var sinceCursor: Int64?

      @Option(help: "Only include transcript entries after this time. Accepts unix seconds, ISO-8601, or 'yyyy/MM/dd HH:mm:ss[Z]'.")
      var sinceTime: String?

      @Flag(help: "Follow live updates to the session over SSE.")
      var follow: Bool = false

      @Flag(help: "In follow mode, stop once the session becomes idle.")
      var stopAfterIdle: Bool = false

      @Option(help: "In follow mode, stop after this many seconds.")
      var timeoutSeconds: Double?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)

        let parsedSinceTime = try sinceTime.flatMap(parseSinceTime)

        if follow {
          let terminal = TerminalCapabilities()
          var printer = SessionStreamPrinter(style: .init(verbosity: shared.verbosity, terminal: terminal))

          let effectiveStopAfterIdle = stopAfterIdle || (timeoutSeconds == nil)
          let stream = try await client.followSessionStream(
            sessionID: sessionId,
            sinceCursor: sinceCursor,
            sinceTime: parsedSinceTime,
            stopAfterIdle: effectiveStopAfterIdle,
            timeoutSeconds: timeoutSeconds,
          )

          for try await event in stream {
            printer.handle(event)
          }
          return
        }

        let response = try await client.getSession(id: sessionId, sinceCursor: sinceCursor, sinceTime: parsedSinceTime)

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
  var username: String?
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

func resolveWuhuUsername(
  _ optionValue: String?,
  env: [String: String] = ProcessInfo.processInfo.environment,
) -> String {
  func cleaned(_ raw: String?) -> String? {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  if let opt = cleaned(optionValue) { return opt }
  if let envValue = cleaned(env["WUHU_USERNAME"]) { return envValue }
  if let cfg = loadClientConfig(), let cfgValue = cleaned(cfg.username) { return cfgValue }

  let user = cleaned(env["USER"]) ?? cleaned(env["USERNAME"]) ?? cleaned(NSUserName()) ?? "unknown_user"
  let host = cleaned(ProcessInfo.processInfo.hostName) ?? "unknown_host"
  return "\(user)@\(host)"
}

func parseSinceTime(_ raw: String) throws -> Date {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    throw ValidationError("Invalid --since-time (empty).")
  }

  if let seconds = Double(trimmed) {
    return Date(timeIntervalSince1970: seconds)
  }

  let iso = ISO8601DateFormatter()
  if let date = iso.date(from: trimmed) {
    return date
  }

  let fmt = DateFormatter()
  fmt.locale = Locale(identifier: "en_US_POSIX")

  if trimmed.hasSuffix("Z") {
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyy/MM/dd HH:mm:ss'Z'"
    if let date = fmt.date(from: trimmed) { return date }
  }

  fmt.timeZone = TimeZone.current
  fmt.dateFormat = "yyyy/MM/dd HH:mm:ss"
  if let date = fmt.date(from: trimmed) { return date }

  throw ValidationError("Invalid --since-time value: \(raw)")
}
