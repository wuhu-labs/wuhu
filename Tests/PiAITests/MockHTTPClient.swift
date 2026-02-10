import Foundation
import PiAI

struct MockHTTPClient: HTTPClient {
  var dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))?
  var sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)?

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
