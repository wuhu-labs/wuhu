import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import JSONValue
import Testing
@testable import WuhuAI

@Suite struct CapacityErrorTests {
  @Test(arguments: ["websocket_backpressure", "response_too_large", "websocket_message_too_large"])
  func capacityCodesOverride429And413OnHTTPAndWebSocket(code: String) async throws {
    for status in [429, 413] {
      var headers = Headers()
      headers[.retryAfter] = "30"
      let responseHeaders = headers
      let value: JSONValue = .object(["code": .string(code), "message": .string("capacity reached")])
      let expected = InferenceError.capacityExceeded(code: code, message: "capacity reached", status: status)
      #expect(ResponsesWebSocketEvents.providerError(value, status: status, headers: headers) == expected)
      for endpoint: any ModelEndpoint in [OpenAIGPTEndpoint(model: "test", apiKey: "offline"), AnthropicEndpoint(model: "test", apiKey: "offline"), CapacityChatEndpoint()] {
        let bound = endpoint.withFetch(FetchClient { _ in Response(status: .init(code: status), headers: responseHeaders, body: .string(JSONValue.object(["error": value]).jsonString())) })
        await #expect(throws: expected) { try await bound.inference(context: Context(messages: [])).collect() }
      }
    }
  }

  @Test(arguments: ["error", "response.failed"], ["websocket_backpressure", "response_too_large", "websocket_message_too_large"])
  func sseCapacityKeepsCode(type: String, code: String) async throws {
    let error: JSONValue = .object(["code": .string(code), "message": .string("capacity reached")])
    let value: JSONValue = type == "error"
      ? .object(["type": .string(type), "status": .integer(429), "error": error])
      : .object(["type": .string(type), "status": .integer(429), "response": .object(["error": error])])
    let endpoint = OpenAIGPTEndpoint(model: "test", apiKey: "offline").withFetch(FetchClient { _ in
      Response(status: .ok, body: .string("data: \(value.jsonString())\n\n"))
    })
    await #expect(throws: InferenceError.capacityExceeded(code: code, message: "capacity reached", status: 429)) {
      try await endpoint.inference(context: Context(messages: [])).collect()
    }
  }

  @Test func realRateLimitRetainsRetryAt() {
    var headers = Headers()
    headers[.retryAfter] = "30"
    let now = Date(timeIntervalSince1970: 100)
    withDependencies { $0.date = .constant(now) } operation: {
      #expect(ResponsesWebSocketEvents.providerError(["code": "rate_limit_exceeded"], status: 429, headers: headers) == .rateLimited(retryAt: now.addingTimeInterval(30)))
    }
  }
}

private struct CapacityChatEndpoint: ChatCompletionsEndpoint {
  let providerID = "offline-chat"
  let model = "test"
  let baseURL = URL(string: "https://example.test/v1")!
}
