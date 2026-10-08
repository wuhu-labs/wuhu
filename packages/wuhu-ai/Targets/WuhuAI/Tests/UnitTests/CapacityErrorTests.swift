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

  @Test(arguments: ["error", "response.failed"], ["status_code", "error.status", "error.status_code"])
  func sseAndWebSocketCapacityShareStatusExtraction(type: String, shape: String) async throws {
    var error: JSONValue = .object(["code": .string("response_too_large")])
    if shape == "error.status" { error = .object(["code": .string("response_too_large"), "status": .integer(413)]) }
    if shape == "error.status_code" { error = .object(["code": .string("response_too_large"), "status_code": .integer(413)]) }
    var event: JSONValue = type == "error"
      ? .object(["type": .string(type), "error": error])
      : .object(["type": .string(type), "response": .object(["error": error])])
    if shape == "status_code" {
      var object = try #require(event.object)
      object["status_code"] = .integer(413)
      event = .object(object)
    }
    let expected = InferenceError.capacityExceeded(code: "response_too_large", message: "response_too_large", status: 413)
    var socket = ResponsesWebSocketEvents()
    #expect(throws: expected) { try socket.accept(event) }
    let text = "data: \(event.jsonString())\n\n"
    let endpoint = OpenAIGPTEndpoint(model: "test", apiKey: "offline").withFetch(FetchClient { _ in
      Response(status: .ok, body: .bytes(Data(text.utf8), contentType: "text/event-stream"))
    })
    await #expect(throws: expected) { try await endpoint.inference(context: Context(messages: [])).collect() }
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
