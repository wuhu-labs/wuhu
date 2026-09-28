import Foundation
import Testing
@testable import WuhuAI

// MARK: - Collecting an inference

extension ModelEndpoint {
  /// Run an inference to completion, returning the final message and its
  /// metadata. Drives the public `inference().stream()` surface and captures
  /// the terminal `.done`.
  func collectFull(
    context: Context,
    options: RequestOptions = RequestOptions(),
  ) async throws -> (message: AssistantMessage, metadata: AssistantMessageMetadata) {
    var message: AssistantMessage?
    var metadata: AssistantMessageMetadata?
    for try await event in inference(context: context, options: options).stream() {
      if case let .done(doneMessage, doneMetadata) = event {
        message = doneMessage
        metadata = doneMetadata
      }
    }
    return (try #require(message), try #require(metadata))
  }
}

// MARK: - Wire dialect (test discriminator)

/// The wire protocol a provider speaks. The production code no longer carries
/// a `dialect` value (each endpoint owns its wire directly); tests that assert
/// dialect-specific behavior reconstruct it from `providerID`.
enum WireDialect { case chatCompletions, responses, anthropic, gemini }

func wireDialect(of providerID: String) -> WireDialect {
  switch providerID {
  case "anthropic", "deepseek-anthropic": .anthropic
  case "openai", "openai-codex": .responses
  case "gemini": .gemini
  default: .chatCompletions
  }
}

// MARK: - Endpoint Factory

/// Create a `ModelEndpoint` for integration testing from env vars.
///
/// In replay mode API keys are never used — the recording fetch client
/// returns fixtures. Use empty-string fallbacks so tests work without env vars.
func makeEndpoint(providerID: String, model: String) -> any ModelEndpoint {
  let apiKey: (String) -> String = { ProcessInfo.processInfo.environment[$0] ?? "" }

  switch providerID {
  case "openai":
    return OpenAIGPTEndpoint(model: model, apiKey: apiKey("OPENAI_API_KEY"))

  case "anthropic":
    return AnthropicEndpoint(model: model, apiKey: apiKey("ANTHROPIC_API_KEY"))

  case "deepseek":
    return DeepSeekChatEndpoint(model: model, apiKey: apiKey("DEEPSEEK_API_KEY"))

  case "deepseek-anthropic":
    return DeepSeekAnthropicEndpoint(model: model, apiKey: apiKey("DEEPSEEK_API_KEY"))

  case "gemini":
    return GeminiEndpoint(model: model, apiKey: apiKey("GEMINI_API_KEY"))

  case "kimi":
    return KimiEndpoint(model: model, apiKey: apiKey("MOONSHOT_API_KEY"))

  default:
    // Unknown provider — return a stub that will fail with a clear error.
    return OpenAIGPTEndpoint(model: model, apiKey: "")
  }
}

/// Create an endpoint from the model matrix.
func makeEndpoint(_ entry: ModelEntry) -> any ModelEndpoint {
  makeEndpoint(providerID: entry.providerID, model: entry.model)
}

// MARK: - Model Entry

/// A single entry in the model matrix for parameterized tests.
struct ModelEntry: Sendable, CustomTestStringConvertible {
  let providerID: String
  let model: String
  let recordingName: String

  var testDescription: String {
    "\(providerID)/\(model)"
  }
}
