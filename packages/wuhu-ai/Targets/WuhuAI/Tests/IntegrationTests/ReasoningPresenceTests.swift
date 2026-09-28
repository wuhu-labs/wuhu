import Foundation
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Reasoning Presence & Opaque Blob

/// Test that reasoning blocks are present and have the correct shape.
///
/// Test 1: Reasoning exists — at least one reasoning block with non-empty text.
/// Test 2: Opaque blob — correct opaque shape per dialect.

private let reasoningPrompt = "Think step by step: if a shirt costs $25 after a 20% discount, what was the original price?"

private let reasoningModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-reasoning-present"),
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-reasoning-present"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-reasoning-present"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-reasoning-present"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-reasoning-present"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-reasoning-present"),
]

/// Non-reasoning models — assert zero reasoning blocks.
private let nonReasoningModels: [ModelEntry] = [
  ModelEntry(providerID: "openai", model: "gpt-4.1-mini", recordingName: "gpt-4.1-mini-reasoning-present"),
]

@Suite struct ReasoningPresenceTests {
  // MARK: - Reasoning Exists

  @Test(arguments: reasoningModels)
  func reasoningBlocksArePresent(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)
      let context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: reasoningPrompt))])),
      ])

      let msgInference = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      )
      let msg = msgInference.message
      let metadata = msgInference.metadata

      // Ensure the model actually produced output.
      #expect(!msg.content.isEmpty, "Expected non-empty content for model \(entry.model)")

      let reasoningBlocks = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }

      // Gemini 2.x with thinkingBudget thinks internally but doesn't return
      // visible reasoning blocks. Verify via usage.reasoningTokens instead.
      if wireDialect(of: endpoint.providerID) == .gemini {
        #expect(
          (metadata.usage?.reasoningTokens ?? 0) > 0,
          "Gemini should have reasoningTokens > 0, got: \(metadata.usage?.reasoningTokens ?? 0)",
        )
      } else {
        #expect(!reasoningBlocks.isEmpty, "Expected at least one reasoning block for model \(entry.model)")

        for block in reasoningBlocks {
          switch block {
          case let .unencrypted(text):
            #expect(!text.isEmpty, "Reasoning block should have non-empty text")
          case let .encrypted(enc):
            #expect(enc.summary != nil || !enc.opaque.isEmpty, "Reasoning block should have non-empty summary or opaque blob")
          }
        }
      }
    }
  }

  // MARK: - No Reasoning for Non-Reasoning Models

  @Test(arguments: nonReasoningModels)
  func nonReasoningModelProducesZeroReasoningBlocks(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)
      let context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: reasoningPrompt))])),
      ])

      let msg = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .none),
      ).message

      // Ensure the model actually produced output.
      #expect(!msg.content.isEmpty, "Non-reasoning model should produce content")

      let reasoningBlocks = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasoningBlocks.isEmpty, "Expected zero reasoning blocks for non-reasoning model \(entry.model)")
    }
  }
}

// MARK: - Reasoning Opaque

private let opaqueModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-reasoning-opaque"),
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-reasoning-opaque"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-reasoning-opaque"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-reasoning-opaque"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-reasoning-opaque"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-reasoning-opaque"),
]

@Suite struct ReasoningOpaqueTests {
  @Test(arguments: opaqueModels)
  func opaqueBlobHasCorrectShape(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)
      let context = Context(messages: [
        .user(UserMessage(content: [.text(TextContent(text: reasoningPrompt))])),
      ])

      let msg = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      ).message

      let reasoningBlocks = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }

      guard !reasoningBlocks.isEmpty else {
        // If no reasoning blocks, the "reasoning present" test should catch this.
        return
      }

      for block in reasoningBlocks {
        switch wireDialect(of: endpoint.providerID) {
        case .anthropic:
          if case let .encrypted(enc) = block {
            #expect(!enc.opaque.isEmpty, "Anthropic reasoning should have non-empty opaque")
          } else {
            #expect(Bool(false), "Anthropic reasoning should be encrypted")
          }

        case .responses:
          if case let .encrypted(enc) = block {
            #expect(!enc.opaque.isEmpty, "Responses reasoning should have non-empty opaque")
          } else {
            #expect(Bool(false), "Responses reasoning should be encrypted")
          }
          #expect(msg.phase != nil, "gpt-5.4 Responses should have phase (commentary/final_answer)")

        case .chatCompletions:
          if case .unencrypted = block { } else {
            #expect(Bool(false), "Chat Completions reasoning should be unencrypted")
          }

        case .gemini:
          break
        }
      }
    }
  }
}
