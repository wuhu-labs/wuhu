import Foundation
import PiAI
import Testing

struct OpenAIResponsesProviderTests {
  @Test func streamsResponsesSSEIntoMessageEvents() async throws {
    let apiKey = "sk-test"

    let http = MockHTTPClient(sseHandler: { request in
      #expect(request.url.absoluteString == "https://api.openai.com/v1/responses")
      let headers = request.headers
      #expect(headers["Authorization"] == "Bearer \(apiKey)")
      #expect(headers["Accept"] == "text/event-stream")

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(data: #"{"type":"response.output_text.delta","delta":"Hello"}"#))
        continuation.yield(.init(data: #"{"type":"response.output_item.done","item":{"content":[{"type":"output_text","text":"Hello"}]}}"#))
        continuation.yield(.init(data: #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#))
        continuation.finish()
      }
    })

    let provider = OpenAIResponsesProvider(http: http)
    let model = Model(id: "gpt-4.1-mini", provider: .openai)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      .user("Say hello"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))

    var done: AssistantMessage?
    for try await event in stream {
      if case let .done(message) = event {
        done = message
      }
    }

    let message = try #require(done)
    #expect(message.content == [.text(.init(text: "Hello"))])
    #expect(message.usage == Usage(inputTokens: 1, outputTokens: 2, totalTokens: 3))
  }

  @Test func capturesReasoningItemAndReplaysItInFollowUpRequests() async throws {
    let apiKey = "sk-test"

    let reasoningItem: [String: Any] = [
      "type": "reasoning",
      "id": "rs_1",
      "summary": [["type": "summary_text", "text": "plan"]],
      "encrypted_content": "enc_abc",
    ]
    let reasoningSignature = try jsonString(reasoningItem)

    let capture = BodyCapture()
    let http = MockHTTPClient(sseHandler: { request in
      if let body = request.body {
        await capture.append(body)
      }

      return AsyncThrowingStream { continuation in
        // First turn: reasoning + tool call.
        continuation.yield(.init(data: #"{"type":"response.output_item.added","item":{"type":"reasoning"}}"#))
        continuation.yield(.init(data: #"{"type":"response.reasoning_summary_text.delta","delta":"plan"}"#))
        continuation.yield(.init(data: #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"plan"}],"encrypted_content":"enc_abc"}}"#))

        continuation.yield(.init(data: #"{"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_1","id":"fc_1","name":"test_tool","arguments":"{\"x\":1}"}}"#))
        continuation.yield(.init(data: #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","id":"fc_1","name":"test_tool","arguments":"{\"x\":1}"}}"#))

        continuation.yield(.init(data: #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#))
        continuation.finish()
      }
    })

    let provider = OpenAIResponsesProvider(http: http)
    let model = Model(id: "gpt-4.1-mini", provider: .openai)

    let firstContext = Context(messages: [.user("hi")])
    let firstStream = try await provider.stream(model: model, context: firstContext, options: .init(apiKey: apiKey))

    var firstDone: AssistantMessage?
    for try await event in firstStream {
      if case let .done(message) = event { firstDone = message }
    }
    let assistant1 = try #require(firstDone)
    #expect(assistant1.content.contains(where: { if case .thinking = $0 { true } else { false } }))
    #expect(assistant1.content.contains(where: { if case .toolCall = $0 { true } else { false } }))

    let toolResult = ToolResultMessage(
      toolCallId: "call_1|fc_1",
      toolName: "test_tool",
      content: [.text(.init(text: "ok"))],
      details: .object([:]),
      isError: false,
    )

    let secondContext = Context(messages: [
      .user("hi"),
      .assistant(assistant1),
      .toolResult(toolResult),
      .user("continue"),
      .assistant(.init(
        provider: .openai,
        model: model.id,
        content: [
          .thinking(.init(thinking: "plan", signature: reasoningSignature)),
        ],
      )),
    ])

    _ = try await provider.stream(model: model, context: secondContext, options: .init(apiKey: apiKey))

    let secondData = try #require(await capture.last())
    let secondBody = try #require(try JSONSerialization.jsonObject(with: secondData) as? [String: Any])
    let input = try #require(secondBody["input"] as? [[String: Any]])
    let hasReasoning = input.contains(where: { ($0["type"] as? String) == "reasoning" && ($0["id"] as? String) == "rs_1" })
    #expect(hasReasoning)
  }

  @Test func omitsToolCallItemIdWhenAssistantModelDiffers() async throws {
    let apiKey = "sk-test"

    let capture = BodyCapture()
    let http = MockHTTPClient(sseHandler: { request in
      if let body = request.body {
        await capture.append(body)
      }
      return AsyncThrowingStream { continuation in
        continuation.finish()
      }
    })

    let provider = OpenAIResponsesProvider(http: http)
    let currentModel = Model(id: "gpt-4.1-mini", provider: .openai)

    let assistantFromDifferentModel = AssistantMessage(
      provider: .openai,
      model: "gpt-4.1",
      content: [
        .toolCall(.init(id: "call_1|fc_1", name: "test_tool", arguments: .object([:]))),
      ],
    )

    let context = Context(messages: [
      .user("hi"),
      .assistant(assistantFromDifferentModel),
      .toolResult(.init(toolCallId: "call_1|fc_1", toolName: "test_tool", content: [.text("ok")])),
    ])

    _ = try await provider.stream(model: currentModel, context: context, options: .init(apiKey: apiKey))

    let data = try #require(await capture.last())
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    let fc = try #require(input.first(where: { ($0["type"] as? String) == "function_call" }))
    #expect(fc["call_id"] as? String == "call_1")
    #expect(fc["id"] == nil)
  }
}

private func jsonString(_ obj: [String: Any]) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
  return String(decoding: data, as: UTF8.self)
}

private actor BodyCapture {
  private var bodies: [Data] = []

  func append(_ data: Data) {
    bodies.append(data)
  }

  func last() -> Data? {
    bodies.last
  }
}
