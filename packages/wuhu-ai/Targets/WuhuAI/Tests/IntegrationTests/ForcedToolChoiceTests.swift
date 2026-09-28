import Foundation
import JSONValue
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Session recipe coverage (2026-07-05 research note)

//
// Per-provider forced-compact recipes, recorded through the production
// dialects: Anthropic = adaptive thinking + named force; OpenAI =
// /v1/responses + named force + reasoning; DeepSeek (Anthropic dialect) =
// named force with thinking disabled for that one turn, and {type:"any"}
// as the only reasoning-plus-forced form.

private let getWeatherTool = Tool(
  name: "get_weather",
  description: "Returns the current weather for a city.",
  parameters: .object([
    "type": .string("object"),
    "properties": .object([
      "city": .object([
        "type": .string("string"),
        "description": .string("City name"),
      ]),
    ]),
    "required": .array([.string("city")]),
  ]),
)

private let compactTool = Tool(
  name: "compact",
  description: "Folds the conversation so far into a durable summary. Call with a summary of everything above.",
  parameters: .object([
    "type": .string("object"),
    "properties": .object([
      "summary": .object([
        "type": .string("string"),
        "description": .string("Summary of the conversation so far"),
      ]),
    ]),
    "required": .array([.string("summary")]),
  ]),
)

private let sessionTools = [getWeatherTool, compactTool]

private func toolCalls(_ message: AssistantMessage) -> [ToolCall] {
  message.content.compactMap { block in
    if case let .toolCall(call) = block { return call }
    return nil
  }
}

private func recordedBody(
  _ recording: String,
  request index: Int,
  file: String = #filePath,
) throws -> JSONValue {
  let url = URL(fileURLWithPath: file)
    .deletingLastPathComponent()
    .appendingPathComponent("Recordings/\(recording)/\(index).request.json")
  struct Recorded: Decodable {
    let body: JSONValue
  }
  return try JSONDecoder().decode(Recorded.self, from: Data(contentsOf: url)).body
}

// MARK: - Forced compact

private let forcedCompactCases: [ModelEntry] = [
  ModelEntry(providerID: "deepseek-anthropic", model: "deepseek-v4-pro", recordingName: "deepseek-anthropic-forced-compact"),
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-5", recordingName: "claude-sonnet-5-forced-compact"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-forced-compact"),
]

@Suite struct ForcedCompactTests {
  @Test(arguments: forcedCompactCases)
  func forcedCompactTurn(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)
      var context = Context(
        systemPrompt: "You are a long-running session agent. Keep answers to one sentence.",
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "What is the capital of France?"))])),
        ],
        tools: sessionTools,
      )

      let normal = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      )
      #expect(toolCalls(normal.message).isEmpty)
      let normalUsage = try #require(normal.metadata.usage)
      #expect(normalUsage.inputTokens > 0)
      #expect(normalUsage.outputTokens > 0)
      #expect(normalUsage.totalTokens > 0)

      context.messages.append(.assistant(normal.message))
      context.messages.append(.user(UserMessage(content: [
        .text(TextContent(text: "Please continue with your tasks.")),
      ])))
      let forced = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high"), toolChoice: .tool(name: "compact")),
      )
      let calls = toolCalls(forced.message)
      #expect(calls.map(\.name) == ["compact"])
      #expect(calls.first?.arguments.json.object?["summary"]?.stringValue?.isEmpty == false)
      let forcedUsage = try #require(forced.metadata.usage)
      #expect(forcedUsage.totalTokens > 0)
    }

    let normalBody = try recordedBody(entry.recordingName, request: 1)
    let forcedBody = try recordedBody(entry.recordingName, request: 2)

    // Cache discipline: the tool list is byte-identical on the forced turn.
    #expect(forcedBody.object?["tools"] == normalBody.object?["tools"])
    #expect(normalBody.object?["tool_choice"] == nil)

    switch entry.providerID {
    case "deepseek-anthropic":
      #expect(forcedBody.object?["tool_choice"] == .object([
        "type": .string("tool"), "name": .string("compact"),
      ]))
      #expect(forcedBody.object?["thinking"] == .object(["type": .string("disabled")]))
      #expect(forcedBody.object?["output_config"] == nil)
      #expect(normalBody.object?["thinking"] == .object(["type": .string("enabled")]))
    case "anthropic":
      #expect(forcedBody.object?["tool_choice"] == .object([
        "type": .string("tool"), "name": .string("compact"),
      ]))
      #expect(forcedBody.object?["thinking"]?.object?["type"] == .string("adaptive"))
      #expect(forcedBody.object?["output_config"] == .object(["effort": .string("high")]))
    case "openai":
      #expect(forcedBody.object?["tool_choice"] == .object([
        "type": .string("function"), "name": .string("compact"),
      ]))
      #expect(forcedBody.object?["reasoning"]?.object?["effort"] == .string("high"))
    default:
      Issue.record("unexpected provider \(entry.providerID)")
    }
  }
}

// MARK: - DeepSeek any-force keeps thinking (dialect divergence)

@Suite struct DeepSeekAnyForceTests {
  @Test func anyForceRunsWithThinkingEnabled() async throws {
    let recording = "deepseek-anthropic-forced-any"
    try await withRecording(recording) {
      let endpoint = makeEndpoint(providerID: "deepseek-anthropic", model: "deepseek-v4-pro")
      let context = Context(
        systemPrompt: "You are a long-running session agent.",
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "Wrap up this conversation."))])),
        ],
        tools: sessionTools,
      )
      let reply = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high"), toolChoice: .any),
      )
      #expect(!toolCalls(reply.message).isEmpty)
      #expect(reply.metadata.usage != nil)
    }

    let body = try recordedBody(recording, request: 1)
    #expect(body.object?["tool_choice"] == .object(["type": .string("any")]))
    #expect(body.object?["thinking"] == .object(["type": .string("enabled")]))
    #expect(body.object?["output_config"] == .object(["effort": .string("high")]))
  }
}

// MARK: - Parallel tool calls, multi-turn, streamed usage

private let parallelCases: [ModelEntry] = [
  ModelEntry(providerID: "deepseek-anthropic", model: "deepseek-v4-pro", recordingName: "deepseek-anthropic-parallel-tools"),
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-5", recordingName: "claude-sonnet-5-parallel-tools"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-parallel-tools"),
]

@Suite struct ParallelToolCallTests {
  @Test(arguments: parallelCases)
  func parallelCallsWithIDMatchedResults(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)
      var context = Context(
        systemPrompt: "You are a helpful assistant.",
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: """
          Fetch the weather for BOTH Paris and Tokyo. Call get_weather twice, \
          in parallel, in this single turn — one call per city.
          """))])),
        ],
        tools: sessionTools,
      )

      let first = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      )
      let calls = toolCalls(first.message)
      #expect(calls.count == 2, "expected two parallel calls, got \(calls.map(\.name))")
      #expect(Set(calls.map(\.id)).count == calls.count)
      #expect(first.metadata.usage != nil)

      context.messages.append(.assistant(first.message))
      for (call, weather) in zip(calls, ["Paris: sunny, 24C", "Tokyo: rain, 19C"]) {
        context.messages.append(.toolResult(ToolResultMessage(
          toolCallId: call.id,
          content: [.text(TextContent(text: weather))],
        )))
      }
      context.messages.append(.user(UserMessage(content: [
        .text(TextContent(text: "Which of the two is warmer?")),
      ])))

      let second = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
      )
      let text = second.message.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(text.localizedCaseInsensitiveContains("paris"), "expected Paris in: \(text)")

      let usage = try #require(second.metadata.usage)
      #expect(usage.inputTokens > 0)
      #expect(usage.outputTokens > 0)
      #expect(usage.totalTokens >= usage.inputTokens + usage.outputTokens)
    }
  }
}
