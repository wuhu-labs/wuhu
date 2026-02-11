import Foundation
import PiAI
import Testing
import WuhuAPI
import WuhuClient

struct WuhuClientTests {
  @Test func listRunnersDecodesResponse() async throws {
    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/runners")
        #expect(request.method == "GET")
        let data = try WuhuJSON.encoder.encode(
          [
            WuhuRunnerInfo(name: "r1", connected: true),
            WuhuRunnerInfo(name: "r2", connected: false),
          ],
        )
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let runners = try await client.listRunners()
    #expect(runners.map(\.name) == ["r1", "r2"])
    #expect(runners.map(\.connected) == [true, false])
  }

  @Test func listEnvironmentsDecodesResponse() async throws {
    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/environments")
        #expect(request.method == "GET")
        let data = try WuhuJSON.encoder.encode(
          [
            WuhuEnvironmentInfo(name: "local", type: "local"),
            WuhuEnvironmentInfo(name: "template", type: "folder-template"),
          ],
        )
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let envs = try await client.listEnvironments()
    #expect(envs.map(\.name) == ["local", "template"])
    #expect(envs.map(\.type) == ["local", "folder-template"])
  }

  @Test func promptStreamDecodesSSEEvents() async throws {
    let http = MockHTTPClient(
      sseHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/prompt")
        #expect(request.headers["Accept"] == "text/event-stream")
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(request.body)
        let decoded = try WuhuJSON.decoder.decode(WuhuPromptRequest.self, from: body)
        #expect(decoded.input == "hello")
        #expect(decoded.detach == false)
        #expect(decoded.user == nil)

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

  @Test func promptStreamSendsUserWhenProvided() async throws {
    let http = MockHTTPClient(
      sseHandler: { request in
        let body = try #require(request.body)
        let decoded = try WuhuJSON.decoder.decode(WuhuPromptRequest.self, from: body)
        #expect(decoded.user == "alice")

        return AsyncThrowingStream { continuation in
          continuation.yield(.init(data: #"{"type":"done"}"#))
          continuation.finish()
        }
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let stream = try await client.promptStream(sessionID: "s1", input: "hello", user: "alice")
    for try await _ in stream {}
  }

  @Test func followSessionStreamSetsAcceptHeaderAndDecodesEvents() async throws {
    let http = MockHTTPClient(
      sseHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/follow")
        #expect(request.headers["Accept"] == "text/event-stream")

        return AsyncThrowingStream { continuation in
          continuation.yield(.init(data: #"{"type":"idle"}"#))
          continuation.yield(.init(data: #"{"type":"done"}"#))
          continuation.finish()
        }
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let stream = try await client.followSessionStream(sessionID: "s1")

    var sawIdle = false
    var sawDone = false

    for try await event in stream {
      switch event {
      case .idle:
        sawIdle = true
      case .done:
        sawDone = true
      default:
        break
      }
    }

    #expect(sawIdle)
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
