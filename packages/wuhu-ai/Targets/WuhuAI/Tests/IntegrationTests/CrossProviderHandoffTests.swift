import Foundation
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Cross-Provider Handoff

/// Test feeding a conversation from one provider to another.
///
/// These are deliberately black-box (`import WuhuAI`, not `@testable`): they feed
/// the context straight to `infer`, so the cross-provider normalization that runs
/// inside `buildRequest` is what's under test. They must NOT reach around the
/// public API to normalize by hand — doing so is what hid a production regression
/// for two refactors.

private let systemPrompt = "You are a helpful assistant. Answer concisely."

// MARK: - Same Dialect Handoff

private let sameDialectPairs: [(String, String, String, String)] = [
  // (sourceProvider, sourceModel, targetProvider, targetModel)
  ("anthropic", "claude-sonnet-4-6", "anthropic", "claude-opus-4-7"),
]

@Suite struct SameDialectHandoffTests {
  @Test(arguments: sameDialectPairs)
  func crossProviderSameDialect(
    sourceProvider: String, sourceModel: String,
    targetProvider: String, targetModel: String,
  ) async throws {
    let recordingName = "\(sourceModel)-to-\(targetModel)-handoff"
    try await withRecording(recordingName) {
      let sourceEndpoint = makeEndpoint(providerID: sourceProvider, model: sourceModel)
      let targetEndpoint = makeEndpoint(providerID: targetProvider, model: targetModel)

      // Turn 1: Source generates a response.
      var context = Context(
        systemPrompt: systemPrompt,
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "What is 2 + 2?"))])),
        ],
      )
      let sourceMsg = try await sourceEndpoint.collectFull(
        context: context,
        options: RequestOptions(),
      ).message
      #expect(!sourceMsg.content.isEmpty)

      // Turn 2: Feed to target.
      context.messages.append(.assistant(sourceMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Are you sure? Double-check."))])))

      // No manual normalization — `infer` normalizes cross-provider internally.
      let targetMsg = try await targetEndpoint.collectFull(
        context: context,
        options: RequestOptions(),
      ).message
      #expect(!targetMsg.content.isEmpty)
    }
  }
}

// MARK: - Different Dialect Handoff

private let crossDialectPairs: [(String, String, String, String)] = [
  ("anthropic", "claude-sonnet-4-6", "deepseek", "deepseek-v4-pro"),
  ("deepseek", "deepseek-v4-pro", "anthropic", "claude-sonnet-4-6"),
]

@Suite struct CrossDialectHandoffTests {
  @Test(arguments: crossDialectPairs)
  func crossProviderDifferentDialect(
    sourceProvider: String, sourceModel: String,
    targetProvider: String, targetModel: String,
  ) async throws {
    let recordingName = "\(sourceModel)-to-\(targetModel)-cross-dialect"
    try await withRecording(recordingName) {
      let sourceEndpoint = makeEndpoint(providerID: sourceProvider, model: sourceModel)
      let targetEndpoint = makeEndpoint(providerID: targetProvider, model: targetModel)

      // Turn 1: Source generates.
      var context = Context(
        systemPrompt: systemPrompt,
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "What is the capital of France?"))])),
        ],
      )
      let sourceMsg = try await sourceEndpoint.collectFull(
        context: context,
        options: RequestOptions(),
      ).message

      // Turn 2: Feed to target.
      context.messages.append(.assistant(sourceMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "What about Germany?"))])))

      // No manual normalization — `infer` normalizes cross-provider internally.
      let targetMsg = try await targetEndpoint.collectFull(
        context: context,
        options: RequestOptions(),
      ).message
      #expect(!targetMsg.content.isEmpty)
    }
  }
}

// MARK: - With Reasoning Handoff

@Suite struct ReasoningHandoffTests {
  @Test
  func reasoningCrossProviderHandoff() async throws {
    let recordingName = "claude-sonnet-4-6-to-deepseek-v4-pro-reasoning-handoff"
    try await withRecording(recordingName) {
      let sourceEndpoint = makeEndpoint(providerID: "anthropic", model: "claude-sonnet-4-6")
      let targetEndpoint = makeEndpoint(providerID: "deepseek", model: "deepseek-v4-pro")

      // Source generates reasoning with signature.
      var context = Context(
        systemPrompt: "Think step by step before answering.",
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "If a train travels at 60 mph for 2.5 hours, how far does it go?"))])),
        ],
      )
      let sourceMsg = try await sourceEndpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      ).message
      #expect(!sourceMsg.content.isEmpty)

      // Verify source has reasoning with signature.
      let sourceReasoning = sourceMsg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(!sourceReasoning.isEmpty, "Source should produce reasoning blocks")
      if let firstReasoning = sourceReasoning.first,
         case let .encrypted(enc) = firstReasoning
      {
        #expect(enc.providerID == "anthropic", "Anthropic reasoning should have providerID 'anthropic'")
      }

      // Handoff to deepseek.
      context.messages.append(.assistant(sourceMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Convert your answer to kilometers."))])))

      // No manual normalization — `infer` normalizes cross-provider internally.
      let targetMsg = try await targetEndpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      ).message
      #expect(!targetMsg.content.isEmpty)

      // Target should receive plain-text reasoning, not signature blocks.
      let targetReasoning = targetMsg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      for block in targetReasoning {
        if case .unencrypted = block { } else {
          #expect(Bool(false), "Cross-provider reasoning should be unencrypted (plain text)")
        }
      }
    }
  }
}

// MARK: - GPT reasoning replayed to Anthropic (regression)

@Suite struct GPTReasoningToAnthropicHandoffTests {
  /// Regression for the production error
  /// `messages.N.content.0: Invalid \`signature\` in \`thinking\` block`.
  ///
  /// A GPT (OpenAI Responses) turn produces an encrypted reasoning block whose
  /// opaque is an OpenAI Fernet token. Replayed to Anthropic, that token must NOT
  /// reach the wire as a `thinking` block signature — Anthropic rejects a foreign
  /// signature. The fix strips it to plain text at the `buildRequest` choke point.
  ///
  /// Black-box on purpose: a straight `.infer` with no manual normalization, so
  /// the live path's normalization is what's exercised.
  @Test func gptReasoningReplaysToAnthropic() async throws {
    try await withRecording("gpt-5.4-reasoning-to-claude-sonnet-4-6-handoff") {
      let gpt = makeEndpoint(providerID: "openai", model: "gpt-5.4")
      let claude = makeEndpoint(providerID: "anthropic", model: "claude-sonnet-4-6")

      var context = Context(
        systemPrompt: "Think briefly before answering.",
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "Name one interesting property of the number 42. Think first."))])),
        ],
      )

      // Turn 1: GPT produces encrypted, OpenAI-origin reasoning.
      let gptMsg = try await gpt.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      ).message
      let hasOpenAIEncryptedReasoning = gptMsg.content.contains { block in
        if case let .reasoning(.encrypted(enc)) = block { return enc.providerID == "openai" }
        return false
      }
      #expect(hasOpenAIEncryptedReasoning, "Expected GPT to produce an encrypted reasoning block")

      // Turn 2: hand the GPT turn to Anthropic — no manual transform. Before the
      // fix this 400'd on the foreign thinking signature.
      context.messages.append(.assistant(gptMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Say it in one sentence."))])))
      let claudeMsg = try await claude.collectFull(
        context: context,
        options: RequestOptions(),
      ).message
      #expect(!claudeMsg.content.isEmpty)
    }
  }
}
