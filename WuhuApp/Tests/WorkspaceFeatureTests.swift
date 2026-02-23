import ComposableArchitecture
import Foundation
import PiAI
import WuhuAPI
@testable import WuhuApp
import WuhuClient
import XCTest

final class WorkspaceFeatureTests: XCTestCase {
  func testRefreshWithoutServerShowsError() async {
    let store = TestStore(initialState: WorkspaceFeature.State()) {
      WorkspaceFeature()
    }

    await store.send(.refresh) {
      $0.error = "Select a server in Settings."
      $0.docs = []
    }
  }

  func testRefreshLoadsDocs() async throws {
    let serverURL = try XCTUnwrap(URL(string: "http://127.0.0.1:5530"))
    let docs = [
      WuhuWorkspaceDocSummary(
        path: "issues/0020.md",
        frontmatter: ["status": .string("open")],
      ),
    ]

    let http = MockHTTPClient(
      dataHandler: { request in
        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:5530/v1/workspace/docs")
        XCTAssertEqual(request.method, "GET")
        let data = try WuhuJSON.encoder.encode(docs)
        return (data, HTTPResponse(statusCode: 200))
      },
    )

    let store = TestStore(
      initialState: {
        var state = WorkspaceFeature.State()
        state.serverURL = serverURL
        return state
      }(),
    ) {
      WorkspaceFeature()
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
      $0.docs = IdentifiedArray(uniqueElements: docs)
    }
  }
}

private struct MockHTTPClient: HTTPClient {
  var dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))?

  init(dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))? = nil) {
    self.dataHandler = dataHandler
  }

  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    guard let dataHandler else {
      throw PiAIError.unsupported("MockHTTPClient.dataHandler not set")
    }
    return try await dataHandler(request)
  }

  func sse(for _: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    throw PiAIError.unsupported("MockHTTPClient.sse not supported")
  }
}
