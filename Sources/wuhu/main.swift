import ArgumentParser
import Foundation
import GRDB
import PiAgent
import PiAI

@inline(never)
private func _ensureGRDBIsLinked() {
  _ = try? DatabaseQueue(path: ":memory:")
}

@main
struct Wuhu: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wuhu",
    abstract: "Wuhu (Swift) – mini demo CLI for PiAI + PiAgent.",
    subcommands: [Agent.self, OpenAI.self, Anthropic.self],
  )

  struct Shared: ParsableArguments {
    @Option(help: "Path to a .env file to load (default: ./.env if present).")
    var envFile: String?
  }

  struct OpenAI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "openai",
      abstract: "Call OpenAI Responses API.",
    )

    @Argument(help: "Prompt to send.")
    var prompt: String

    @Option(help: "OpenAI model id.")
    var model: String = "gpt-4.1-mini"

    @OptionGroup
    var shared: Shared

    func run() async throws {
      _ensureGRDBIsLinked()
      try DotEnv.loadIfPresent(path: shared.envFile)

      let provider = OpenAIResponsesProvider()
      let model = Model(id: model, provider: .openai)
      let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
        ChatMessage(role: .user, content: prompt),
      ])

      for try await event in try await provider.stream(model: model, context: context) {
        switch event {
        case .start:
          break
        case let .textDelta(delta, _):
          FileHandle.standardOutput.write(Data(delta.utf8))
        case .done:
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
      }
    }
  }

  struct Anthropic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "anthropic",
      abstract: "Call Anthropic Messages API.",
    )

    @Argument(help: "Prompt to send.")
    var prompt: String

    @Option(help: "Anthropic model id.")
    var model: String = "claude-sonnet-4-5"

    @OptionGroup
    var shared: Shared

    func run() async throws {
      _ensureGRDBIsLinked()
      try DotEnv.loadIfPresent(path: shared.envFile)

      let provider = AnthropicMessagesProvider()
      let model = Model(id: model, provider: .anthropic)
      let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
        ChatMessage(role: .user, content: prompt),
      ])

      for try await event in try await provider.stream(model: model, context: context) {
        switch event {
        case .start:
          break
        case let .textDelta(delta, _):
          FileHandle.standardOutput.write(Data(delta.utf8))
        case .done:
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
      }
    }
  }

  struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "agent",
      abstract: "Run a minimal agent loop with tool calling.",
    )

    enum Backend: String, ExpressibleByArgument, Sendable {
      case openai
      case anthropic
    }

    @Option(help: "Backend/provider to use.")
    var backend: Backend = .openai

    @Option(help: "Model id (defaults vary by backend).")
    var model: String?

    @Option(help: "System prompt (optional).")
    var systemPrompt: String =
      "You are a helpful assistant. For any weather question, you must use the `weather` tool for each city you need. Do not guess."

    @OptionGroup
    var shared: Shared

    func run() async throws {
      _ensureGRDBIsLinked()
      try DotEnv.loadIfPresent(path: shared.envFile)

      let prompt = readStdinPrompt()
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("No prompt provided on stdin.")
      }

      let provider: Provider
      let modelId: String
      switch backend {
      case .openai:
        provider = .openai
        modelId = model ?? "gpt-4.1-mini"
      case .anthropic:
        provider = .anthropic
        modelId = model ?? "claude-sonnet-4-5"
      }

      let weatherTool = makeWeatherTool()

      let agent = PiAgent.Agent(.init(initialState: .init(
        systemPrompt: systemPrompt,
        model: .init(id: modelId, provider: provider),
        tools: [weatherTool],
      )))

      final class DeltaTracker: @unchecked Sendable {
        var sawAssistantTextDelta = false
      }
      let tracker = DeltaTracker()

      _ = agent.subscribe { event in
        switch event {
        case let .messageStart(message):
          if message.role == "assistant" {
            tracker.sawAssistantTextDelta = false
          }
        case let .messageUpdate(_, assistantMessageEvent):
          if case let .textDelta(delta, _) = assistantMessageEvent {
            tracker.sawAssistantTextDelta = true
            FileHandle.standardOutput.write(Data(delta.utf8))
          }
        case let .messageEnd(message):
          if message.role == "assistant", tracker.sawAssistantTextDelta == false {
            if let text = assistantText(from: message), !text.isEmpty {
              FileHandle.standardOutput.write(Data(text.utf8))
            }
            if let error = assistantError(from: message) {
              FileHandle.standardError.write(Data("\n[agent:error] \(error)\n".utf8))
            }
          }
          if message.role == "error", case let .custom(custom) = message {
            FileHandle.standardError.write(Data("\n[agent:error] \(custom.content)\n".utf8))
          }
        case let .toolExecutionStart(toolCallId, toolName, args):
          FileHandle.standardError.write(Data("\n[tool:start] \(toolName) id=\(toolCallId) args=\(args)\n".utf8))
        case let .toolExecutionEnd(toolCallId, toolName, result, isError):
          FileHandle.standardError.write(
            Data("[tool:end] \(toolName) id=\(toolCallId) error=\(isError) result=\(result.content)\n".utf8),
          )
        default:
          break
        }
      }

      try await agent.prompt(prompt)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func readStdinPrompt() -> String {
      if let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty {
        return String(decoding: data, as: UTF8.self)
      }
      return ""
    }

    private func assistantText(from message: AgentMessage) -> String? {
      guard case let .llm(m) = message, case let .assistant(assistant) = m else { return nil }
      return assistant.content.compactMap { part in
        if case let .text(text) = part { return text.text }
        return nil
      }.joined()
    }

    private func assistantError(from message: AgentMessage) -> String? {
      guard case let .llm(m) = message, case let .assistant(assistant) = m else { return nil }
      guard assistant.stopReason == .error else { return nil }
      return assistant.errorMessage
    }

    private func makeWeatherTool() -> AgentTool {
      let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
          "city": .object([
            "type": .string("string"),
            "description": .string("City name, e.g. San Francisco"),
          ]),
        ]),
        "required": .array([.string("city")]),
      ])

      let tool = Tool(
        name: "weather",
        description: "Get the current weather for a city (demo tool; returns synthetic data).",
        parameters: schema,
      )

      return AgentTool(tool: tool, label: "Weather") { _, params, _, _ in
        let city = params.asObject?["city"]?.asString ?? "Unknown"
        let report = WeatherTool.fakeWeatherReport(for: city)
        return AgentToolResult(content: report, details: .object(["city": .string(city)]))
      }
    }
  }
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

enum WeatherTool {
  static func fakeWeatherReport(for city: String) -> String {
    let baseTempF = switch city.lowercased() {
    case "san francisco", "sf":
      60
    case "san diego", "sd":
      75
    case "tokyo":
      70
    case "new york", "nyc":
      55
    default:
      65
    }

    // Add a little randomness, but keep San Diego hotter than San Francisco for the demo.
    let jitter = Int.random(in: -2 ... 2)
    let tempF = baseTempF + jitter
    let humidity = Int.random(in: 35 ... 75)
    let windMph = Int.random(in: 0 ... 18)
    return """
    Weather for \(city):
    - temperature_f: \(tempF)
    - humidity_percent: \(humidity)
    - wind_mph: \(windMph)
    """
  }
}
