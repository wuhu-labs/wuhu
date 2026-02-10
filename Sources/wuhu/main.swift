import ArgumentParser
import Foundation
import PiAI
import WuhuAPI
import WuhuClient
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

      @Option(help: "Session id returned by create-session.")
      var sessionId: String

      @Option(help: "Max assistant turns (safety valve).")
      var maxTurns: Int = 12

      @Argument(parsing: .remaining, help: "Prompt text.")
      var prompt: [String] = []

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)

        let text = prompt.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("Expected a prompt.") }

        let stream = try await client.promptStream(sessionID: sessionId, input: text, maxTurns: maxTurns)
        var printed = false

        for try await event in stream {
          switch event {
          case let .toolExecutionStart(_, toolName, args):
            FileHandle.standardError.write(Data("\n[tool] \(toolName) args=\(formatJSON(args))\n".utf8))

          case let .toolExecutionEnd(_, toolName, result, isError):
            let suffix = isError ? " (error)" : ""
            let text = result.content.compactMap { block -> String? in
              if case let .text(text, _) = block { return text }
              return nil
            }.joined()
            if !text.isEmpty {
              FileHandle.standardError.write(Data("[tool] \(toolName) result=\(text)\(suffix)\n".utf8))
            }

          case let .assistantTextDelta(delta):
            printed = true
            FileHandle.standardOutput.write(Data(delta.utf8))

          case .done:
            if printed { FileHandle.standardOutput.write(Data("\n".utf8)) }
          }
        }
      }
    }

    struct GetSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "get-session",
        abstract: "Print session metadata and full transcript.",
      )

      @Option(help: "Session id.")
      var sessionId: String

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let response = try await client.getSession(id: sessionId)

        let session = response.session
        FileHandle.standardOutput.write(Data("session \(session.id)\n".utf8))
        FileHandle.standardOutput.write(Data("provider \(session.provider.rawValue)\n".utf8))
        FileHandle.standardOutput.write(Data("model \(session.model)\n".utf8))
        FileHandle.standardOutput.write(Data("environment \(session.environment.name)\n".utf8))
        FileHandle.standardOutput.write(Data("cwd \(session.cwd)\n".utf8))
        FileHandle.standardOutput.write(Data("createdAt \(session.createdAt)\n".utf8))
        FileHandle.standardOutput.write(Data("updatedAt \(session.updatedAt)\n".utf8))
        FileHandle.standardOutput.write(Data("headEntryID \(session.headEntryID)\n".utf8))
        FileHandle.standardOutput.write(Data("tailEntryID \(session.tailEntryID)\n".utf8))

        for entry in response.transcript {
          switch entry.payload {
          case let .header(h):
            FileHandle.standardOutput.write(Data("\n# header\n".utf8))
            FileHandle.standardOutput.write(Data("systemPrompt:\n\(h.systemPrompt)\n".utf8))

          case let .message(m):
            FileHandle.standardOutput.write(Data("\n# message \(entry.id)\n".utf8))
            FileHandle.standardOutput.write(Data(renderMessage(m).utf8))

          case let .toolExecution(t):
            FileHandle.standardOutput.write(Data("\n# tool_execution \(entry.id)\n".utf8))
            FileHandle.standardOutput.write(Data("\(t.phase.rawValue) \(t.toolName) toolCallId=\(t.toolCallId)\n".utf8))

          case let .custom(customType, data):
            FileHandle.standardOutput.write(Data("\n# custom \(entry.id)\n".utf8))
            FileHandle.standardOutput.write(Data("customType \(customType)\n".utf8))
            if let data {
              FileHandle.standardOutput.write(Data("data \(formatJSON(data))\n".utf8))
            }

          case let .unknown(type, payload):
            FileHandle.standardOutput.write(Data("\n# unknown(\(type)) \(entry.id)\n".utf8))
            FileHandle.standardOutput.write(Data("\(formatJSON(payload))\n".utf8))
          }
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

private func renderMessage(_ m: WuhuPersistedMessage) -> String {
  switch m {
  case let .user(u):
    "user: \(renderBlocks(u.content))\n"
  case let .assistant(a):
    "assistant: \(renderBlocks(a.content))\n"
  case let .toolResult(t):
    "tool_result(\(t.toolName)): \(renderBlocks(t.content))\n"
  case let .customMessage(c):
    "custom_message(\(c.customType)): \(renderBlocks(c.content))\n"
  case let .unknown(role, payload):
    "unknown_message(\(role)): \(formatJSON(payload))\n"
  }
}

private func renderBlocks(_ blocks: [WuhuContentBlock]) -> String {
  blocks.compactMap { block -> String? in
    switch block {
    case let .text(text, _):
      text
    case let .toolCall(_, name, arguments):
      "[tool_call \(name) args=\(formatJSON(arguments))]"
    case .reasoning:
      nil
    }
  }.joined()
}

private func formatJSON(_ value: JSONValue) -> String {
  if let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys]),
     let s = String(data: data, encoding: .utf8)
  {
    return s
  }
  return "{}"
}
