import Foundation
import PiAI
import Testing
import WuhuAPI
import WuhuClient

struct WuhuClientTests {
  @Test func promptStreamDecodesSSEEvents() async throws {
    let http = MockHTTPClient(
      sseHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/prompt")
        #expect(request.headers["Accept"] == "text/event-stream")
        #expect(request.headers["Content-Type"] == "application/json")

        return AsyncThrowingStream { continuation in
          continuation.yield(.init(data: #"{"type":"assistant_text_delta","delta":"Hi"}"#))
          continuation.yield(.init(data: #"{"type":"done"}"#))
          continuation.finish()
        }
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let stream = try await client.promptStream(sessionID: "s1", input: "hello")

    var deltas: [String] = []
    var sawDone = false

    for try await event in stream {
      switch event {
      case let .assistantTextDelta(delta):
        deltas.append(delta)
      case .done:
        sawDone = true
      default:
        break
      }
    }

    #expect(deltas == ["Hi"])
    #expect(sawDone)
  }
}

private struct MockHTTPClient: HTTPClient {
  var dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))?
  var sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)?

  init(
    dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))? = nil,
    sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)? = nil,
  ) {
    self.dataHandler = dataHandler
    self.sseHandler = sseHandler
  }

  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    guard let dataHandler else {
      throw PiAIError.unsupported("MockHTTPClient.dataHandler not set")
    }
    return try await dataHandler(request)
  }

  func sse(for request: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    guard let sseHandler else {
      throw PiAIError.unsupported("MockHTTPClient.sseHandler not set")
    }
    return try await sseHandler(request)
  }
}
