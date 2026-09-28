import Foundation
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Tool Call Loop

/// Test tool call loop with double_number tool.
///
/// Turn 1: "Use the double_number tool to double 21."
///   → stopReason == .stop, has toolCall with name "double_number"
/// Tool result: 42
/// Turn 2: "Now say the result in a sentence."
///   → stopReason == .stop, text contains "42"

private let toolLoopModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-tool-loop"),
  ModelEntry(providerID: "anthropic", model: "claude-opus-4-7", recordingName: "claude-opus-4-7-tool-loop"),
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-tool-loop"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-tool-loop"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-tool-loop"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-tool-loop"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-tool-loop"),
]

/// Build the double_number tool definition.
private let doubleNumberTool = Tool(
  name: "double_number",
  description: "Doubles a number and returns the result.",
  parameters: .object([
    "type": .string("object"),
    "properties": .object([
      "number": .object([
        "type": .string("integer"),
        "description": .string("The number to double"),
      ]),
    ]),
    "required": .array([.string("number")]),
  ]),
)

@Suite struct ToolCallLoopTests {
  @Test(arguments: toolLoopModels)
  func toolCallDoubleNumber(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)

      // Turn 1: Request tool call.
      var context = Context(
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "Use the double_number tool to double 21."))])),
        ],
        tools: [doubleNumberTool],
      )
      let msg1 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(),
      ).message

      let toolCalls = msg1.content.compactMap { block -> ToolCall? in
        if case let .toolCall(tc) = block { return tc }
        return nil
      }
      #expect(!toolCalls.isEmpty, "Expected at least one tool call")
      if let firstCall = toolCalls.first {
        #expect(firstCall.name == "double_number")
      }

      // Provide tool result.
      context.messages.append(.assistant(msg1))
      for call in toolCalls {
        context.messages.append(.toolResult(ToolResultMessage(
          toolCallId: call.id,
          content: [.text(TextContent(text: "42"))],
        )))
      }

      // Turn 2: Follow-up.
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Now say the result in a sentence."))])))
      let msg2 = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(),
      ).message

      let allText = msg2.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(allText.contains("42"), "Expected response to mention '42', got: \(allText)")
    }
  }
}

// MARK: - Foreign Tool Call ID Replay

@Suite struct ToolCallIDNormalizationTests {
  /// Regression for the reported Cloudflare error
  /// `tool_use.id: String should match pattern '^[a-zA-Z0-9_-]+$'`.
  ///
  /// A session that started on OpenAI Responses persisted its tool call as a
  /// compound `call_id|item_id` domain ID. When the session later switched to
  /// Anthropic, the request builder emitted that ID verbatim and Cloudflare
  /// rejected it. The fix normalizes tool call IDs unconditionally in
  /// `buildRequest`, so the foreign ID reaches the wire as a valid `tool_use.id`
  /// and its matching `tool_result` agrees.
  ///
  /// This deliberately does *not* call `transformedContext` — it feeds the
  /// context straight to `infer`, exercising the same choke-point normalization
  /// the live server path relies on.
  @Test func compoundToolCallIDReplaysToAnthropic() async throws {
    try await withRecording("compound-tool-id-anthropic-replay") {
      let endpoint = makeEndpoint(providerID: "anthropic", model: "claude-sonnet-4-6")

      // A real OpenAI Responses compound ID — invalid for Anthropic because of `|`.
      let foreignID = "call_6rZUVJ683bIdPVFK9KrqhmsL|fc_00c62836549affdb016a2d04e3e2c8819bad650bf8f8b4a37c"

      let context = Context(
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "Use the double_number tool to double 21."))])),
          .assistant(AssistantMessage(content: [
            .toolCall(ToolCall(
              id: foreignID,
              name: "double_number",
              arguments: .object(["number": .number(21)]),
            )),
          ])),
          .toolResult(ToolResultMessage(
            toolCallId: foreignID,
            content: [.text(TextContent(text: "42"))],
          )),
          .user(UserMessage(content: [.text(TextContent(text: "Now say the result in a sentence."))])),
        ],
        tools: [doubleNumberTool],
      )

      let msg = try await endpoint.collectFull(context: context, options: RequestOptions()).message
      let allText = msg.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(allText.contains("42"), "Expected response to mention '42', got: \(allText)")
    }
  }
}
