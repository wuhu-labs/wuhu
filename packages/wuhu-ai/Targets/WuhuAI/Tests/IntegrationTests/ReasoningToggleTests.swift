import Foundation
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Reasoning Toggle

/// Test that reasoning can be toggled between turns without errors.
///
/// Variants:
/// - open-to-closed: `.effort("high")` → `.none`
/// - closed-to-open: `.none` → `.effort("high")`
/// - closed-to-different: `.none` → `.effort("low")`

private let toggleModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-reasoning-toggle"),
  ModelEntry(providerID: "anthropic", model: "claude-opus-4-7", recordingName: "claude-opus-4-7-reasoning-toggle"),
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-reasoning-toggle"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-reasoning-toggle"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-reasoning-toggle"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-reasoning-toggle"),
]

@Suite struct ReasoningToggleTests {
  @Test(arguments: toggleModels)
  func reasoningOpenToClosed(entry: ModelEntry) async throws {
    try await withRecording("\(entry.recordingName)-open-to-closed") {
      let endpoint = makeEndpoint(entry)

      // Turn 1: reasoning = effort("high")
      var context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Explain quantum computing in one paragraph."))])),
      ])
      let msg1 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      ).message
      #expect(!msg1.content.isEmpty)

      // Turn 2: reasoning = .none
      context.messages.append(.assistant(msg1))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Now explain it to a five-year-old."))])))
      let msg2 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .none),
      ).message
      #expect(!msg2.content.isEmpty)
    }
  }

  @Test(arguments: toggleModels)
  func reasoningClosedToOpen(entry: ModelEntry) async throws {
    try await withRecording("\(entry.recordingName)-closed-to-open") {
      let endpoint = makeEndpoint(entry)

      // Turn 1: reasoning = .none
      var context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Explain quantum computing in one paragraph."))])),
      ])
      let msg1 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .none),
      ).message
      #expect(!msg1.content.isEmpty)

      // Turn 2: reasoning = effort("high")
      context.messages.append(.assistant(msg1))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Now explain it to a five-year-old."))])))
      let msg2 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      ).message
      #expect(!msg2.content.isEmpty)
    }
  }

  @Test(arguments: toggleModels)
  func reasoningClosedToDifferent(entry: ModelEntry) async throws {
    try await withRecording("\(entry.recordingName)-closed-to-different") {
      let endpoint = makeEndpoint(entry)

      // Turn 1: reasoning = .none
      var context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Explain quantum computing in one paragraph."))])),
      ])
      let msg1 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .none),
      ).message
      #expect(!msg1.content.isEmpty)

      // Turn 2: reasoning = effort("low")
      context.messages.append(.assistant(msg1))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Now explain it to a five-year-old."))])))
      let msg2 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("low")),
      ).message
      #expect(!msg2.content.isEmpty)
    }
  }
}
