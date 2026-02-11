import ComposableArchitecture
import Foundation
import PiAI
import WuhuAPI
@testable import WuhuApp
import WuhuClient
import XCTest

final class SessionsFeatureTests: XCTestCase {
  func testRefreshWithoutServerShowsError() async {
    let store = TestStore(initialState: SessionsFeature.State()) {
      SessionsFeature()
    }

    await store.send(.refresh) {
      $0.error = "Select a server in Settings."
      $0.sessions = []
    }
  }

  func testRefreshLoadsSessions() async throws {
    let serverURL = try XCTUnwrap(URL(string: "http://127.0.0.1:5530"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let session = WuhuSession(
      id: "s1",
      provider: .openai,
      model: "gpt",
      environment: WuhuEnvironment(name: "local", type: .local, path: "/tmp"),
      cwd: "/tmp",
      runnerName: nil,
      parentSessionID: nil,
      createdAt: now,
      updatedAt: now,
      headEntryID: 1,
      tailEntryID: 1,
    )

    let http = MockHTTPClient(
      dataHandler: { request in
        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:5530/v2/sessions")
        XCTAssertEqual(request.method, "GET")
        let data = try WuhuJSON.encoder.encode([session])
        return (data, HTTPResponse(statusCode: 200))
      },
    )

    let store = TestStore(
      initialState: {
        var state = SessionsFeature.State()
        state.serverURL = serverURL
        return state
      }(),
    ) {
      SessionsFeature()
    } withDependencies: {
      $0.wuhuClientProvider = WuhuClientProvider(
        make: { baseURL in
          WuhuClient(baseURL: baseURL, http: http)
        },
      )
    }

    await store.send(.refresh) {
      $0.isLoading = true
      $0.error = nil
    }

    await store.receive(\.refreshResponse) {
      $0.isLoading = false
      $0.error = nil
      $0.sessions = IdentifiedArray(uniqueElements: [session])
    }
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
