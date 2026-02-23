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
extension WuhuEnvironmentType: ExpressibleByArgument {}

@main
struct WuhuCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wuhu",
    abstract: "Wuhu (Swift) – server + client for persisted coding-agent sessions.",
    subcommands: [
      Server.self,
      Client.self,
      Env.self,
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
        ListSkills.self,
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

      @Option(help: "Environment identifier (UUID or unique name).")
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
          let qid = try await client.enqueue(sessionID: sessionId, input: text, user: username, lane: .followUp)
          FileHandle.standardOutput.write(Data("enqueued  id=\(qid)\n".utf8))
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

    struct ListSkills: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list-skills",
        abstract: "List skills loaded into a session's context.",
      )

      @Option(help: "Session id (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)

        let response = try await client.getSession(id: sessionId)
        let skills = WuhuSkills.extract(from: response.transcript)

        if skills.isEmpty {
          FileHandle.standardOutput.write(Data("(no skills)\n".utf8))
          return
        }

        for skill in skills {
          FileHandle.standardOutput.write(Data("\(skill.name)\t\(skill.description)\t\(skill.filePath)\n".utf8))
        }
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

  struct Env: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "env",
      abstract: "Manage environments (create, list, update, delete).",
      subcommands: [
        Create.self,
        List.self,
        Get.self,
        Update.self,
        Delete.self,
      ],
    )

    struct Shared: ParsableArguments {
      @Option(help: "Server base URL (default: read ~/.wuhu/client.yml, else http://127.0.0.1:5530).")
      var server: String?

      @Flag(help: "Print JSON instead of human-readable output.")
      var json: Bool = false
    }

    struct Create: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new environment definition.",
      )

      @Option(help: "Unique environment name.")
      var name: String

      @Option(help: "Environment type (local, folder-template).")
      var type: WuhuEnvironmentType

      @Option(help: "For local: working directory path. For folder-template: workspaces root directory.")
      var path: String

      @Option(help: "For folder-template: template folder path.")
      var templatePath: String?

      @Option(help: "For folder-template: optional startup script path.")
      var startupScript: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)

        if type == .folderTemplate {
          let tp = (templatePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          guard !tp.isEmpty else { throw ValidationError("folder-template requires --template-path") }
        }

        let env = try await client.createEnvironment(.init(
          name: name,
          type: type,
          path: path,
          templatePath: templatePath,
          startupScript: startupScript,
        ))

        try printEnvironment(env, asJSON: shared.json)
      }
    }

    struct List: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List environments.",
      )

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let envs = try await client.listEnvironments()

        if shared.json {
          try printJSON(envs)
          return
        }

        printEnvironmentTable(envs)
      }
    }

    struct Get: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get an environment by UUID or name.",
      )

      @Argument(help: "Environment UUID or name.")
      var identifier: String

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let env = try await client.getEnvironment(identifier)
        try printEnvironment(env, asJSON: shared.json)
      }
    }

    struct Update: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an environment by UUID or name.",
      )

      @Argument(help: "Environment UUID or name.")
      var identifier: String

      @Option(help: "New name (optional).")
      var name: String?

      @Option(help: "New type (optional).")
      var type: WuhuEnvironmentType?

      @Option(help: "New path (optional).")
      var path: String?

      @Option(help: "New template path (optional).")
      var templatePath: String?

      @Flag(help: "Clear templatePath (sets it to null).")
      var clearTemplatePath: Bool = false

      @Option(help: "New startup script path (optional).")
      var startupScript: String?

      @Flag(help: "Clear startupScript (sets it to null).")
      var clearStartupScript: Bool = false

      @OptionGroup
      var shared: Shared

      func run() async throws {
        guard name != nil || type != nil || path != nil || templatePath != nil || startupScript != nil || clearTemplatePath || clearStartupScript else {
          throw ValidationError("No changes specified.")
        }

        var req = WuhuUpdateEnvironmentRequest()
        req.name = name
        req.type = type
        req.path = path

        if clearTemplatePath {
          req.templatePath = .some(nil)
        } else if let templatePath {
          req.templatePath = .some(templatePath)
        }
        if clearStartupScript {
          req.startupScript = .some(nil)
        } else if let startupScript {
          req.startupScript = .some(startupScript)
        }

        let client = try makeClient(shared.server)
        let env = try await client.updateEnvironment(identifier, request: req)
        try printEnvironment(env, asJSON: shared.json)
      }
    }

    struct Delete: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an environment by UUID or name.",
      )

      @Argument(help: "Environment UUID or name.")
      var identifier: String

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        try await client.deleteEnvironment(identifier)
        if shared.json {
          try printJSON(["deleted": identifier])
          return
        }
        FileHandle.standardOutput.write(Data("deleted  \(identifier)\n".utf8))
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

private func printEnvironment(_ env: WuhuEnvironmentDefinition, asJSON: Bool) throws {
  if asJSON {
    try printJSON(env)
    return
  }
  FileHandle.standardOutput.write(Data("id: \(env.id)\n".utf8))
  FileHandle.standardOutput.write(Data("name: \(env.name)\n".utf8))
  FileHandle.standardOutput.write(Data("type: \(env.type.rawValue)\n".utf8))
  FileHandle.standardOutput.write(Data("path: \(env.path)\n".utf8))
  if let templatePath = env.templatePath {
    FileHandle.standardOutput.write(Data("templatePath: \(templatePath)\n".utf8))
  }
  if let startupScript = env.startupScript {
    FileHandle.standardOutput.write(Data("startupScript: \(startupScript)\n".utf8))
  }
}

private func printEnvironmentTable(_ envs: [WuhuEnvironmentDefinition]) {
  let idHeader = "ID"
  let nameHeader = "NAME"

  let idWidth = max(idHeader.count, envs.map(\.id.count).max() ?? 0)
  let nameWidth = max(nameHeader.count, envs.map(\.name.count).max() ?? 0)

  func pad(_ s: String, to width: Int) -> String {
    if s.count >= width { return s }
    return s + String(repeating: " ", count: width - s.count)
  }

  FileHandle.standardOutput.write(Data("\(pad(idHeader, to: idWidth))  \(pad(nameHeader, to: nameWidth))\n".utf8))
  for env in envs {
    FileHandle.standardOutput.write(Data("\(pad(env.id, to: idWidth))  \(pad(env.name, to: nameWidth))\n".utf8))
  }
}

private func printJSON(_ value: some Encodable) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .secondsSince1970
  let data = try encoder.encode(value)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
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
