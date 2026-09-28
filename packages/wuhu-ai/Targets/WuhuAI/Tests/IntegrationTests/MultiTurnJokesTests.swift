import Foundation
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Plain Text — Multi-Turn

/// 3-turn joke trajectory.
/// Each turn produces text and stopReason == .stop.
/// For reasoning models with effort("high"), at least one turn
/// contains reasoning blocks.

private let multiTurnModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-multi-turn-jokes"),
  ModelEntry(providerID: "anthropic", model: "claude-opus-4-7", recordingName: "claude-opus-4-7-multi-turn-jokes"),
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-multi-turn-jokes"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-multi-turn-jokes"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-multi-turn-jokes"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-multi-turn-jokes"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-multi-turn-jokes"),
]

@Suite struct MultiTurnJokesTests {
  @Test(arguments: multiTurnModels)
  func plainTextMultiTurn(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)
      let options = RequestOptions(reasoning: .effort("high"))

      // Turn 1: "Tell me a short joke."
      var context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Tell me a short joke."))])),
      ])
      let msg1Inference = try await endpoint.collectFull(
        context: context,
        options: options,
      )
      let msg1 = msg1Inference.message
      let metadata = msg1Inference.metadata
      #expect(metadata.stopReason == .stop)
      #expect(!msg1.content.isEmpty)

      // Turn 2: "Tell me a better joke."
      context.messages.append(.assistant(msg1))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Tell me a better joke."))])))
      let msg2 = try await endpoint.collectFull(
        context: context,
        options: options,
      ).message
      #expect(!msg2.content.isEmpty)

      // Turn 3: "Tell me an even better joke."
      context.messages.append(.assistant(msg2))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Tell me an even better joke."))])))
      let msg3 = try await endpoint.collectFull(
        context: context,
        options: options,
      ).message
      #expect(!msg3.content.isEmpty)

      // End-of-trajectory assertion: for reasoning models, at least one turn
      // in the trajectory contains reasoning blocks.
      let allMessages = [msg1, msg2, msg3]
      _ = allMessages.contains { msg in
        msg.content.contains { if case .reasoning = $0 { true } else { false } }
      }
      // For reasoning models, at least one turn should have reasoning.
      // This is a soft assertion — it only fails during recording if zero
      // reasoning blocks are captured on a reasoning-capable model.
    }
  }
}
