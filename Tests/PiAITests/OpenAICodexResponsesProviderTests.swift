import Foundation
import PiAI
import Testing

struct OpenAICodexResponsesProviderTests {
  @Test func streamsSSEEventsIntoMessageEvents() async throws {
    let token = makeTestJWT(accountId: "acc_test")

    let http = MockHTTPClient(sseHandler: { request in
      #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
      let headers = normalizedHeaders(request)
      #expect(headers["authorization"] == "Bearer \(token)")
      #expect(headers["chatgpt-account-id"] == "acc_test")
      #expect(headers["openai-beta"] == "responses=experimental")
      #expect(headers["originator"] == "pi")
      #expect(headers["accept"] == "text/event-stream")
      #expect(headers["x-api-key"] == nil)

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(data: #"{"type":"response.output_item.added","item":{"type":"message","id":"msg_1","role":"assistant","status":"in_progress","content":[]}}"#))
        continuation.yield(.init(data: #"{"type":"response.content_part.added","part":{"type":"output_text","text":""}}"#))
        continuation.yield(.init(data: #"{"type":"response.output_text.delta","delta":"Hello"}"#))
        continuation.yield(.init(data: #"{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#))
        continuation.yield(.init(data: #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8,"input_tokens_details":{"cached_tokens":0}}}}"#))
        continuation.finish()
      }
    })

    let provider = OpenAICodexResponsesProvider(http: http)
    let model = Model(id: "gpt-5.1-codex", provider: .openaiCodex)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      ChatMessage(role: .user, content: "Say hello"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: token))
    var sawTextDelta = false
    var sawDone = false

    for try await event in stream {
      switch event {
      case let .textDelta(delta, _):
        if delta == "Hello" { sawTextDelta = true }
      case let .done(message):
        sawDone = true
        #expect(message.content == [.text(.init(text: "Hello"))])
        #expect(message.usage == Usage(inputTokens: 5, outputTokens: 3, totalTokens: 8))
      default:
        break
      }
    }

    #expect(sawTextDelta)
    #expect(sawDone)
  }

  @Test func setsSessionHeadersAndPromptCacheKeyWhenSessionIdProvided() async throws {
    let token = makeTestJWT(accountId: "acc_test")
    let sessionId = "test-session-123"

    let http = MockHTTPClient(sseHandler: { request in
      let headers = normalizedHeaders(request)
      #expect(headers["conversation_id"] == sessionId)
      #expect(headers["session_id"] == sessionId)

      let body = try #require(request.body)
      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      let promptCacheKey = json?["prompt_cache_key"] as? String
      let retention = json?["prompt_cache_retention"] as? String
      #expect(promptCacheKey == sessionId)
      #expect(retention == "in-memory")

      return AsyncThrowingStream { continuation in
        continuation.finish()
      }
    })

    let provider = OpenAICodexResponsesProvider(http: http)
    let model = Model(id: "gpt-5.1-codex", provider: .openaiCodex)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      ChatMessage(role: .user, content: "Say hello"),
    ])

    _ = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: token, sessionId: sessionId),
    )
  }
}

private func makeTestJWT(accountId: String) -> String {
  // header and signature are irrelevant for our parsing.
  let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
  let payload = base64URL(Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountId)"}}"#.utf8))
  return "\(header).\(payload).sig"
}

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func normalizedHeaders(_ request: HTTPRequest) -> [String: String] {
  Dictionary(
    uniqueKeysWithValues: request.headers.map { key, value in
      (key.lowercased(), value)
    },
  )
}
