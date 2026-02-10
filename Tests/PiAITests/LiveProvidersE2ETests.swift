import Foundation
import PiAI
import Testing

struct LiveProvidersE2ETests {
  @Test(.enabled(if: shouldRunLiveTests && hasOpenAIKey))
  func openAI_smoke() async throws {
    let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])

    let provider = OpenAIResponsesProvider()
    let model = Model(id: "gpt-4.1-mini", provider: .openai)
    let context = Context(systemPrompt: "Follow instructions exactly.", messages: [
      .user("Output exactly: HELLO"),
    ])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(temperature: 0, maxTokens: 16, apiKey: apiKey),
    )

    var finalText = ""
    for try await event in stream {
      if case let .done(message) = event {
        if case let .text(part)? = message.content.first {
          finalText = part.text
        }
      }
    }

    #expect(finalText.contains("HELLO"))
  }

  @Test(.enabled(if: shouldRunLiveTests && hasAnthropicKey))
  func anthropic_smoke() async throws {
    let apiKey = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])

    let provider = AnthropicMessagesProvider()
    let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
    let context = Context(systemPrompt: "Follow instructions exactly.", messages: [
      .user("Output exactly: HELLO"),
    ])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(temperature: 0, maxTokens: 16, apiKey: apiKey),
    )

    var finalText = ""
    for try await event in stream {
      if case let .done(message) = event {
        if case let .text(part)? = message.content.first {
          finalText = part.text
        }
      }
    }

    #expect(finalText.contains("HELLO"))
  }
}

private let shouldRunLiveTests = ProcessInfo.processInfo.environment["PIAI_LIVE_TESTS"] == "1"
private let hasOpenAIKey = !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
private let hasAnthropicKey = !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
