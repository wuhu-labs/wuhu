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
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/prompt")
        #expect(request.method == "POST")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(request.body)
        let decoded = try WuhuJSON.decoder.decode(WuhuPromptRequest.self, from: body)
        #expect(decoded.input == "hello")
        #expect(decoded.detach == true)
        #expect(decoded.user == nil)

        let now = Date(timeIntervalSince1970: 0)
        let userEntry = WuhuSessionEntry(
          id: 2,
          sessionID: "s1",
          parentEntryID: 1,
          createdAt: now,
          payload: .message(.user(.init(user: "unknown_user", content: [.text(text: "hello", signature: nil)], timestamp: now))),
        )
        let data = try WuhuJSON.encoder.encode(WuhuPromptDetachedResponse(userEntry: userEntry))
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
      sseHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/follow?sinceCursor=1&stopAfterIdle=1")
        #expect(request.headers["Accept"] == "text/event-stream")

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
      dataHandler: { request in
        let body = try #require(request.body)
        let decoded = try WuhuJSON.decoder.decode(WuhuPromptRequest.self, from: body)
        #expect(decoded.user == "alice")

        let now = Date(timeIntervalSince1970: 0)
        let userEntry = WuhuSessionEntry(
          id: 2,
          sessionID: "s1",
          parentEntryID: 1,
          createdAt: now,
          payload: .message(.user(.init(user: "alice", content: [.text(text: "hello", signature: nil)], timestamp: now))),
        )
        let data = try WuhuJSON.encoder.encode(WuhuPromptDetachedResponse(userEntry: userEntry))
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
      sseHandler: { _ in
        AsyncThrowingStream { continuation in
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

  @Test func setSessionModelPostsAndDecodesResponse() async throws {
    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/model")
        #expect(request.method == "POST")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(request.body)
        let decoded = try WuhuJSON.decoder.decode(WuhuSetSessionModelRequest.self, from: body)
        #expect(decoded.provider == .openai)
        #expect(decoded.model == "gpt-5.2-codex")
        #expect(decoded.reasoningEffort == .high)

        let session = WuhuSession(
          id: "s1",
          provider: .openai,
          model: "gpt-5.2-codex",
          environment: .init(name: "local", type: .local, path: "/tmp"),
          cwd: "/tmp",
          runnerName: nil,
          parentSessionID: nil,
          createdAt: Date(timeIntervalSince1970: 1),
          updatedAt: Date(timeIntervalSince1970: 2),
          headEntryID: 1,
          tailEntryID: 2,
        )
        let response = WuhuSetSessionModelResponse(
          session: session,
          selection: .init(provider: .openai, model: "gpt-5.2-codex", reasoningEffort: .high),
          applied: true,
        )
        let data = try WuhuJSON.encoder.encode(response)
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let response = try await client.setSessionModel(sessionID: "s1", provider: .openai, model: "gpt-5.2-codex", reasoningEffort: .high)
    #expect(response.applied == true)
    #expect(response.session.model == "gpt-5.2-codex")
    #expect(response.selection.reasoningEffort == .high)
  }

  @Test func stopSessionPostsAndDecodesResponse() async throws {
    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v2/sessions/s1/stop")
        #expect(request.method == "POST")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(request.body)
        let decoded = try WuhuJSON.decoder.decode(WuhuStopSessionRequest.self, from: body)
        #expect(decoded.user == "alice")

        let now = Date(timeIntervalSince1970: 0)
        let stopEntry = WuhuSessionEntry(
          id: 2,
          sessionID: "s1",
          parentEntryID: 1,
          createdAt: now,
          payload: .message(.customMessage(.init(
            customType: WuhuCustomMessageTypes.executionStopped,
            content: [.text(text: "Execution stopped", signature: nil)],
            details: nil,
            display: true,
            timestamp: now,
          ))),
        )
        let response = WuhuStopSessionResponse(repairedEntries: [], stopEntry: stopEntry)
        let data = try WuhuJSON.encoder.encode(response)
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let response = try await client.stopSession(sessionID: "s1", user: "alice")
    #expect(response.stopEntry?.id == 2)
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
