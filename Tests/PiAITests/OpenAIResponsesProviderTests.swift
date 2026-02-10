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
      ChatMessage(role: .user, content: "Say hello"),
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
}
