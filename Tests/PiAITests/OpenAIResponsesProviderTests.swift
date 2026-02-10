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

  @Test func replaysReasoningItemsInRequestBody() async throws {
    setenv("PIAI_OPENAI_STORE", "true", 1)
    defer { unsetenv("PIAI_OPENAI_STORE") }

    let apiKey = "sk-test"

    let http = MockHTTPClient(sseHandler: { request in
      let body = try #require(request.body)
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

      #expect(json["store"] as? Bool == true)

      let input = try #require(json["input"] as? [[String: Any]])
      let reasoning = input.first(where: { ($0["type"] as? String) == "reasoning" })
      #expect(reasoning?["id"] as? String == "rsn_1")
      #expect(reasoning?["encrypted_content"] as? String == "enc_1")
      #expect((reasoning?["summary"] as? [Any]) != nil)

      return AsyncThrowingStream { continuation in
        continuation.finish()
      }
    })

    let provider = OpenAIResponsesProvider(http: http)
    let model = Model(id: "gpt-5.2-codex", provider: .openai)

    let assistant = AssistantMessage(provider: .openai, model: model.id, content: [
      .reasoning(.init(id: "rsn_1", encryptedContent: "enc_1")),
      .toolCall(.init(id: "call_1|item_1", name: "read", arguments: .object([:]))),
    ])

    let context = Context(systemPrompt: nil, messages: [
      .user("Run a tool"),
      .assistant(assistant),
      .toolResult(.init(toolCallId: "call_1|item_1", toolName: "read", content: [.text(.init(text: "ok"))])),
      .user("Continue"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey, reasoningEffort: .low))
    for try await _ in stream {}
  }
}
