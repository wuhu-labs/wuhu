import ArgumentParser
import Foundation
import PiAI

@main
struct Wuhu: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wuhu",
    abstract: "Wuhu (Swift) – small demo CLI for PiAI providers.",
    subcommands: [OpenAI.self, Anthropic.self],
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
