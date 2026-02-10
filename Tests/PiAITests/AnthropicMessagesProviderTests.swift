import Foundation
import PiAI
import Testing

struct AnthropicMessagesProviderTests {
  @Test func streamsAnthropicSSEIntoMessageEvents() async throws {
    let apiKey = "ak-test"

    let http = MockHTTPClient(sseHandler: { request in
      #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
      let headers = normalizedHeaders(request)
      #expect(headers["x-api-key"] == apiKey)
      #expect(headers["accept"] == "text/event-stream")

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(event: "content_block_delta", data: #"{"delta":{"type":"text_delta","text":"Hello"}}"#))
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
    let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
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
  }
}

private func normalizedHeaders(_ request: HTTPRequest) -> [String: String] {
  Dictionary(
    uniqueKeysWithValues: request.headers.map { key, value in
      (key.lowercased(), value)
    },
  )
}
