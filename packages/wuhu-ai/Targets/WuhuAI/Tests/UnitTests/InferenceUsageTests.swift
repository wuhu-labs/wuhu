import JSONValue
import Testing
@testable import WuhuAI

@Suite struct InferenceUsageTests {
  private func events(_ frames: [(String?, String)]) -> AsyncThrowingStream<SSEEvent, any Error> {
    AsyncThrowingStream { continuation in
      for (event, data) in frames { continuation.yield(SSEEvent(event: event ?? "message", data: data)) }
      continuation.finish()
    }
  }

  private func metadata(_ stream: AsyncThrowingStream<InferenceEvent, any Error>) async throws -> AssistantMessageMetadata {
    for try await event in stream {
      if case let .done(_, metadata) = event { return metadata }
    }
    throw ProbeFailure.incomplete
  }

  @Test func anthropicSeparatesCacheWritesAndReadsWithoutDoubleCounting() async throws {
    let value = try await metadata(parseAnthropicStream(events([
      ("message_start", #"{"message":{"model":"claude-served","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70}}}"#),
      ("message_delta", #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}"#),
      ("message_stop", "{}"),
    ]), providerID: "anthropic", model: "configured"))
    let usage = try #require(value.usage)
    #expect(usage.inputTokens == 300)
    #expect(usage.uncachedInputTokens == 30)
    #expect(usage.cacheReadTokens == 200)
    #expect(usage.cacheWriteTokens == 70)
    #expect(usage.outputTokens == 50)
    #expect(usage.reasoningTokens == nil)
    #expect(value.servedModel == "claude-served")
  }

  @Test(arguments: ["openai", "codex"])
  func responsesAndCodexSubtractCachedInputAndKeepReasoningWithinOutput(provider: String) async throws {
    let value = try await metadata(parseResponsesStream(events([
      (nil, #"{"type":"response.completed","response":{"status":"completed","model":"sol-served","usage":{"input_tokens":224721,"input_tokens_details":{"cached_tokens":222976},"output_tokens":1000,"output_tokens_details":{"reasoning_tokens":750},"total_tokens":225721}}}"#),
    ]), providerID: provider, model: "configured"))
    let usage = try #require(value.usage)
    #expect(usage.uncachedInputTokens == 1745)
    #expect(usage.cacheReadTokens == 222_976)
    #expect(usage.cacheWriteTokens == 0)
    #expect(usage.outputTokens == 1000)
    #expect(usage.reasoningTokens == 750)
    #expect(value.servedModel == "sol-served")
  }

  @Test func chatCompletionsSubtractCachedPromptTokens() async throws {
    let value = try await metadata(parseChatCompletionsStream(events([
      (nil, #"{"model":"chat-served","choices":[],"usage":{"prompt_tokens":300,"prompt_tokens_details":{"cached_tokens":250},"completion_tokens":80,"completion_tokens_details":{"reasoning_tokens":60},"total_tokens":380}}"#),
      (nil, "[DONE]"),
    ]), providerID: "openai", model: "configured"))
    let usage = try #require(value.usage)
    #expect(usage.uncachedInputTokens == 50)
    #expect(usage.cacheReadTokens == 250)
    #expect(usage.cacheWriteTokens == 0)
    #expect(usage.outputTokens == 80)
    #expect(usage.reasoningTokens == 60)
    #expect(value.servedModel == "chat-served")
  }

  @Test func geminiAddsThoughtsToBilledOutput() async throws {
    let value = try await metadata(parseGeminiStream(events([
      (nil, #"{"modelVersion":"gemini-served","candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":300,"cachedContentTokenCount":250,"candidatesTokenCount":20,"thoughtsTokenCount":80,"totalTokenCount":400}}"#),
    ]), providerID: "gemini", model: "configured"))
    let usage = try #require(value.usage)
    #expect(usage.uncachedInputTokens == 50)
    #expect(usage.cacheReadTokens == 250)
    #expect(usage.cacheWriteTokens == 0)
    #expect(usage.outputTokens == 100)
    #expect(usage.reasoningTokens == 80)
    #expect(value.servedModel == "gemini-served")
  }

  @Test func absentReasoningIsNotReportedZero() async throws {
    let response = try await metadata(parseResponsesStream(events([
      (nil, #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":5}}}"#),
    ]), providerID: "openai", model: "configured"))
    let chat = try await metadata(parseChatCompletionsStream(events([
      (nil, #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#),
      (nil, "[DONE]"),
    ]), providerID: "openai", model: "configured"))
    let gemini = try await metadata(parseGeminiStream(events([
      (nil, #"{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":5}}"#),
    ]), providerID: "gemini", model: "configured"))
    for value in [response, chat, gemini] {
      #expect(try #require(value.usage).reasoningTokens == nil)
      #expect(value.servedModel == nil)
    }
  }

  private enum ProbeFailure: Error { case incomplete }
}
