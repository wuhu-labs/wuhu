import ArgumentParser
import Foundation
import WuhuCore

extension WuhuProvider: ExpressibleByArgument {}

@main
struct WuhuCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wuhu",
    abstract: "Wuhu (Swift) – persisted agent sessions (SQLite/GRDB).",
    subcommands: [
      CreateSession.self,
      Prompt.self,
      GetSession.self,
      ListSessions.self,
    ],
  )

  struct Shared: ParsableArguments {
    @Option(help: "Path to a .env file to load (default: ./.env if present).")
    var envFile: String?

    @Option(help: "SQLite database path (default: ~/.wuhu/wuhu.sqlite). Use :memory: for ephemeral.")
    var db: String?
  }

  struct CreateSession: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "create-session",
      abstract: "Create a new persisted session.",
    )

    @Option(help: "Provider for this session.")
    var provider: WuhuProvider

    @Option(help: "Model id (defaults depend on provider).")
    var model: String?

    @Option(help: "System prompt for the agent.")
    var systemPrompt: String = defaultSystemPrompt

    @Option(help: "Working directory for this session (default: current directory).")
    var cwd: String?

    @OptionGroup
    var shared: Shared

    func run() async throws {
      try DotEnv.loadIfPresent(path: shared.envFile)
      let service = try makeService(dbPath: shared.db)

      let resolvedModel = model ?? defaultModel(for: provider)
      let resolvedCwd: String = {
        if let cwd, !cwd.isEmpty {
          return ToolPath.resolveToCwd(cwd, cwd: FileManager.default.currentDirectoryPath)
        }
        return FileManager.default.currentDirectoryPath
      }()

      let session = try await service.createSession(
        provider: provider,
        model: resolvedModel,
        systemPrompt: systemPrompt,
        cwd: resolvedCwd,
      )
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
      try DotEnv.loadIfPresent(path: shared.envFile)
      let service = try makeService(dbPath: shared.db)

      let text = prompt.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw ValidationError("Expected a prompt.") }

      let stream = try await service.promptStream(sessionID: sessionId, input: text, maxTurns: maxTurns)
      var printed = false

      for try await event in stream {
        switch event {
        case let .toolExecutionStart(_, toolName, args):
          FileHandle.standardError.write(Data("\n[tool] \(toolName) args=\(formatJSON(args))\n".utf8))

        case let .toolExecutionEnd(_, toolName, result, isError):
          let suffix = isError ? " (error)" : ""
          let text = result.content.compactMap { block -> String? in
            if case let .text(t) = block { return t.text }
            return nil
          }.joined()
          if !text.isEmpty {
            FileHandle.standardError.write(Data("[tool] \(toolName) result=\(text)\(suffix)\n".utf8))
          }

        case let .assistantTextDelta(delta):
          printed = true
          FileHandle.standardOutput.write(Data(delta.utf8))

        case .done:
          if printed {
            FileHandle.standardOutput.write(Data("\n".utf8))
          }
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
      let service = try makeService(dbPath: shared.db)
      let session = try await service.getSession(id: sessionId)
      let transcript = try await service.getTranscript(sessionID: sessionId)

      FileHandle.standardOutput.write(Data("session \(session.id)\n".utf8))
      FileHandle.standardOutput.write(Data("provider \(session.provider.rawValue)\n".utf8))
      FileHandle.standardOutput.write(Data("model \(session.model)\n".utf8))
      FileHandle.standardOutput.write(Data("createdAt \(session.createdAt)\n".utf8))
      FileHandle.standardOutput.write(Data("updatedAt \(session.updatedAt)\n".utf8))
      FileHandle.standardOutput.write(Data("headEntryID \(session.headEntryID)\n".utf8))
      FileHandle.standardOutput.write(Data("tailEntryID \(session.tailEntryID)\n".utf8))

      for entry in transcript {
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
      let service = try makeService(dbPath: shared.db)
      let sessions = try await service.listSessions(limit: limit)

      for s in sessions {
        FileHandle.standardOutput.write(Data("\(s.id)  \(s.provider.rawValue)  \(s.model)  updatedAt=\(s.updatedAt)\n".utf8))
      }
    }
  }
}

private let defaultSystemPrompt = [
  "You are a coding agent.",
  "Use tools to inspect and modify the repository in your working directory.",
  "Prefer read/grep/find/ls over guessing file contents.",
  "When making changes, use edit for surgical replacements and write for new files.",
  "Use bash to run builds/tests and gather precise outputs.",
].joined(separator: "\n")

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

private func makeService(dbPath: String?) throws -> WuhuService {
  let resolvedPath = try resolveDatabasePath(dbPath)
  try ensureDirectoryExists(forDatabasePath: resolvedPath)

  let store = try SQLiteSessionStore(path: resolvedPath)
  return WuhuService(store: store)
}

private func resolveDatabasePath(_ explicit: String?) throws -> String {
  if let explicit, !explicit.isEmpty { return (explicit as NSString).expandingTildeInPath }
  let home = FileManager.default.homeDirectoryForCurrentUser
  return home.appendingPathComponent(".wuhu/wuhu.sqlite").path
}

private func ensureDirectoryExists(forDatabasePath path: String) throws {
  guard path != ":memory:" else { return }
  let url = URL(fileURLWithPath: path)
  let dir = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

enum DotEnv {
  static func loadIfPresent(path explicitPath: String?) throws {
    let fm = FileManager.default
    let path = explicitPath ?? ".env"
    guard fm.fileExists(atPath: path) else { return }
    let text = try String(contentsOfFile: path, encoding: .utf8)

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }

      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }

      let key = parts[0].trimmingCharacters(in: .whitespaces)
      var value = parts[1].trimmingCharacters(in: .whitespaces)

      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }

      if ProcessInfo.processInfo.environment[key] == nil {
        setenv(key, value, 0)
      }
    }
  }
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
