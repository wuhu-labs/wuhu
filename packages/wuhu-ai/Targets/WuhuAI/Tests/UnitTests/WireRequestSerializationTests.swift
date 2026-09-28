import Fetch
import Foundation
import JSONValue
import Testing
import WuhuAI

@Suite struct WireRequestSerializationTests {
  @Test func providerWireRequestsUseDeterministicObjectKeyOrdering() async throws {
    let context = Self.longComplexContext()
    let options = RequestOptions(
      temperature: 0.2,
      maxTokens: 4096,
      reasoning: .budget(1024),
    )

    for testCase in Self.endpointMatrix() {
      let recorder = RequestBodyRecorder()
      let fetch = FetchClient { request in
        let body = try await request.body?.text() ?? ""
        await recorder.append(body)
        throw FakeNetworkError()
      }
      let endpoint = testCase.endpoint.withFetch(fetch)

      for _ in 0 ..< 10 {
        let stream = endpoint.inference(context: context, options: options).stream()
        do {
          for try await _ in stream {}
          Issue.record("\(testCase.name) unexpectedly completed without hitting fake fetch")
        } catch {
          // Expected: this test hijacks the request before any network call.
          // The fake fetch throws `FakeNetworkError`, which the inference seam
          // normalizes into a bounded `InferenceError`. `error` is *statically*
          // typed `InferenceError` here (the stream's `Failure`), with no
          // `as`-cast and no fallback `catch` — an unrecognized sentinel
          // normalizes to `.other`.
          let inferenceError: InferenceError = error
          guard case .other = inferenceError else {
            Issue.record("\(testCase.name) failed with unexpected InferenceError: \(error)")
            return
          }
        }
      }

      let bodies = await recorder.bodies()
      #expect(bodies.count == 10, "\(testCase.name) should issue one request per run")
      #expect(Set(bodies).count == 1, "\(testCase.name) should produce identical wire bodies across runs")

      for body in bodies {
        let value = try #require(JSONValue.parse(body), "\(testCase.name) body should be valid JSON")
        #expect(value.jsonString() == body, "\(testCase.name) body should already be canonical insertion-order JSON")
        #expect(value.jsonString(sortedKeys: true) != body, "\(testCase.name) wire body should be insertion-order, not sorted")
      }
    }
  }

  private static func endpointMatrix() -> [(name: String, endpoint: any ModelEndpoint)] {
    [
      (
        "openai-responses",
        OpenAIGPTEndpoint(model: "gpt-5.4-wire-determinism", apiKey: "test-key", promptCacheKey: "session-wire-determinism"),
      ),
      (
        "openai-codex",
        OpenAICodexEndpoint(model: "gpt-5.4-codex-wire-determinism", jwt: "test-jwt", environment: "wuhu-test", chatgptAccountID: "acct-test", sessionID: "session-wire-determinism", originator: "wuhu"),
      ),
      (
        "anthropic",
        AnthropicEndpoint(model: "claude-sonnet-4-6-wire-determinism", apiKey: "test-key", promptCache: .fiveMinutes),
      ),
      (
        "deepseek-chat",
        DeepSeekChatEndpoint(model: "deepseek-v4-pro-wire-determinism", apiKey: "test-key"),
      ),
      (
        "deepseek-anthropic",
        DeepSeekAnthropicEndpoint(model: "deepseek-v4-pro-wire-determinism", apiKey: "test-key"),
      ),
      (
        "gemini",
        GeminiEndpoint(model: "gemini-2.5-flash-wire-determinism", apiKey: "test-key"),
      ),
      (
        "kimi",
        KimiEndpoint(model: "kimi-k2.6-wire-determinism", apiKey: "test-key"),
      ),
      (
        "qwen",
        QwenEndpoint(model: "qwen-wire-determinism", apiKey: "test-key", preserveThinking: true),
      ),
      (
        "minimax",
        MiniMaxEndpoint(model: "minimax-wire-determinism", apiKey: "test-key"),
      ),
    ]
  }

  private static func longComplexContext() -> Context {
    let longPrompt = (0 ..< 40)
      .map { index in
        "Section \(index): keep object key ordering deterministic across provider requests, tool schemas, tool calls, and nested JSON payloads."
      }
      .joined(separator: "\n")

    return Context(
      systemPrompt: """
      You are testing deterministic provider request serialization.
      \(longPrompt)
      """,
      messages: [
        .user(.init(content: [
          .text(.init(text: """
          Please inspect this deliberately long prompt and call the planning tool if useful.
          \(longPrompt)
          """)),
        ])),
        .assistant(.init(content: [
          .reasoning(.encrypted(.init(
            providerID: "anthropic",
            model: "claude-sonnet-4-6-wire-determinism",
            summary: "Need to preserve deterministic request JSON.",
            opaque: "signature_wire_determinism",
            id: "rs_wire_determinism",
          ))),
          .toolCall(.init(
            id: "call_wire_determinism_001",
            name: "plan_patch",
            arguments: Self.complexToolArguments(),
          )),
        ])),
        .toolResult(.init(
          toolCallId: "call_wire_determinism_001",
          content: [.text(.init(text: "Recorded fake tool result with enough content to stabilize a realistic transcript."))],
        )),
        .user(.init(content: [
          .text(.init(text: "Now answer with the exact minimal fix and do not make a real network request.")),
        ])),
      ],
      tools: [
        Tool(
          name: "plan_patch",
          description: "Plans a deterministic JSON serialization patch without touching the network.",
          parameters: Self.complexToolSchema(),
        ),
      ],
    )
  }

  private static func complexToolArguments() -> ToolArguments {
    .object([
      "zeta": .array([
        .object(["beta": .number(2), "alpha": .number(1)]),
        .object(["delta": .bool(true), "gamma": .string("value")]),
      ]),
      "alpha": .object([
        "nested": .object([
          "k3": .array([.number(3), .number(2), .number(1)]),
          "k1": .string("first"),
          "k2": .bool(false),
        ]),
      ]),
      "middle": .string("payload"),
    ])
  }

  private static func complexToolSchema() -> JSONValue {
    .object([
      "type": .string("object"),
      "required": .array([.string("objective"), .string("steps")]),
      "additionalProperties": .bool(false),
      "properties": .object([
        "steps": .object([
          "type": .string("array"),
          "items": .object([
            "type": .string("object"),
            "required": .array([.string("title"), .string("risk")]),
            "properties": .object([
              "title": .object(["type": .string("string")]),
              "risk": .object(["enum": .array([.string("low"), .string("medium"), .string("high")])]),
              "metadata": .object([
                "type": .string("object"),
                "properties": .object([
                  "owner": .object(["type": .string("string")]),
                  "deterministic": .object(["type": .string("boolean")]),
                ]),
              ]),
            ]),
          ]),
        ]),
        "objective": .object([
          "type": .string("string"),
          "description": .string("The implementation objective."),
        ]),
      ]),
    ])
  }
}

private actor RequestBodyRecorder {
  private var recordedBodies: [String] = []

  func append(_ body: String) {
    recordedBodies.append(body)
  }

  func bodies() -> [String] {
    recordedBodies
  }
}

private struct FakeNetworkError: Error {}
