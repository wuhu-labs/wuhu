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
    abstract: "Wuhu (Swift) – small demo CLI for PiAI providers.",
    subcommands: [OpenAI.self, Anthropic.self, Agent.self],
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
        .user(prompt),
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
        .user(prompt),
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
      abstract: "Run a minimal tool-using agent loop (stdin → tools → final response).",
      subcommands: [OpenAI.self, Anthropic.self],
    )

    struct SharedAgent: ParsableArguments {
      @Option(help: "Path to a .env file to load (default: ./.env if present).")
      var envFile: String?

      @Option(help: "Max assistant turns (safety valve).")
      var maxTurns: Int = 12
    }

    struct OpenAI: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "openai",
        abstract: "Agent loop via OpenAI Responses API.",
      )

      @Option(help: "OpenAI model id.")
      var model: String = "gpt-4.1-mini"

      @OptionGroup
      var shared: SharedAgent

      func run() async throws {
        try await runAgent(provider: .openai, modelId: model, shared: shared)
      }
    }

    struct Anthropic: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "anthropic",
        abstract: "Agent loop via Anthropic Messages API.",
      )

      @Option(help: "Anthropic model id.")
      var model: String = "claude-sonnet-4-5"

      @OptionGroup
      var shared: SharedAgent

      func run() async throws {
        try await runAgent(provider: .anthropic, modelId: model, shared: shared)
      }
    }

    private static func runAgent(provider: Provider, modelId: String, shared: SharedAgent) async throws {
      _ensureGRDBIsLinked()
      try DotEnv.loadIfPresent(path: shared.envFile)

      let prompt = readAllStdin().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !prompt.isEmpty else {
        throw ValidationError("Expected a prompt on stdin.")
      }

      let tool = makeSimulatedWeatherTool()
      let model = Model(id: modelId, provider: provider)

      let agent = PiAgent.Agent(opts: .init(
        initialState: .init(
          systemPrompt: [
            "You are a terminal agent.",
            "You have a weather tool. Always call it when asked about weather, and prefer tool results over guesses.",
            "If asked to compare cities, call the tool for each city and compare temperatures.",
          ].joined(separator: "\n"),
          model: model,
          tools: [tool],
        ),
        maxTurns: shared.maxTurns,
      ))

      let eventsTask = Task {
        var printedStreamingText = false
        do {
          for try await event in agent.events {
            switch event {
            case let .toolExecutionStart(_, toolName, args):
              FileHandle.standardError.write(Data("\n[tool] \(toolName) args=\(formatJSON(args))\n".utf8))
            case let .messageUpdate(message, assistantEvent):
              if case .assistant = message, case let .textDelta(delta, _) = assistantEvent {
                printedStreamingText = true
                FileHandle.standardOutput.write(Data(delta.utf8))
              }
            case let .messageEnd(message):
              if case let .assistant(m) = message, printedStreamingText == false {
                let text = m.content.compactMap { block -> String? in
                  if case let .text(part) = block { return part.text }
                  return nil
                }.joined()
                if !text.isEmpty {
                  FileHandle.standardOutput.write(Data(text.utf8))
                }
              }
              if case .assistant = message {
                FileHandle.standardOutput.write(Data("\n".utf8))
                printedStreamingText = false
              }
            default:
              continue
            }
          }
        } catch {
          // Ignore cancellation and surface other errors as best-effort stderr output.
          if (error as? CancellationError) == nil {
            FileHandle.standardError.write(Data("\n[agent events error] \(String(describing: error))\n".utf8))
          }
        }
      }

      defer { eventsTask.cancel() }

      try await agent.prompt(prompt)
      await agent.waitForIdle()
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

private func readAllStdin() -> String {
  let data = FileHandle.standardInput.readDataToEndOfFile()
  return String(decoding: data, as: UTF8.self)
}

private func makeSimulatedWeatherTool() -> AnyAgentTool {
  struct Params: Decodable, Sendable {
    var city: String
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "city": .object([
        "type": .string("string"),
        "description": .string("City name, e.g. San Francisco"),
      ]),
    ]),
    "required": .array([.string("city")]),
    "additionalProperties": .bool(false),
  ])

  return AnyAgentTool(
    name: "weather",
    label: "Weather",
    description: "Get simulated weather data for a city (demo tool; returns fake data).",
    parametersSchema: schema,
    execute: { (_: String, params: Params) in
      let report = simulatedWeather(for: params.city)
      let text = "\(report.city): \(report.temperatureC)°C, \(report.condition) (simulated)"
      return AgentToolResult(
        content: [.text(text)],
        details: .object([
          "city": .string(report.city),
          "temperatureC": .number(Double(report.temperatureC)),
          "condition": .string(report.condition),
          "source": .string("simulated"),
        ]),
      )
    },
  )
}

private struct WeatherReport: Sendable {
  var city: String
  var temperatureC: Int
  var condition: String
}

private func simulatedWeather(for cityRaw: String) -> WeatherReport {
  let city = cityRaw.trimmingCharacters(in: .whitespacesAndNewlines)
  let normalized = city.lowercased()

  // Deterministic "fake" data: stable enough for demos/tests.
  let fixed: [String: WeatherReport] = [
    "san francisco": .init(city: "San Francisco", temperatureC: 18, condition: "foggy"),
    "san diego": .init(city: "San Diego", temperatureC: 24, condition: "sunny"),
    "tokyo": .init(city: "Tokyo", temperatureC: 29, condition: "humid"),
    "new york": .init(city: "New York", temperatureC: 6, condition: "windy"),
  ]
  if let report = fixed[normalized] { return report }

  let hash = stableHash(normalized)
  let temp = 5 + Int(hash % 26) // 5..30
  let conditions = ["sunny", "cloudy", "rainy", "windy", "foggy"]
  let condition = conditions[Int((hash / 31) % UInt64(conditions.count))]
  return .init(city: city.isEmpty ? "Unknown" : city, temperatureC: temp, condition: condition)
}

private func stableHash(_ s: String) -> UInt64 {
  // FNV-1a 64-bit
  var hash: UInt64 = 14_695_981_039_346_656_037
  for b in s.utf8 {
    hash ^= UInt64(b)
    hash &*= 1_099_511_628_211
  }
  return hash
}

private func formatJSON(_ value: JSONValue) -> String {
  if let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys]),
     let s = String(data: data, encoding: .utf8)
  {
    return s
  }
  return "{}"
}
