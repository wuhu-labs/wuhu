import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import JSONValue
@testable import SpaceServer
import Testing

private let routePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8) + Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])

@Suite struct CapabilityRouteTests {
  @Test func imageAndSearchHTTPUseTheSharedAuthoritativeResolution() async throws {
    let harness = try Harness(credentials: .init { id in id == "codex" ? .chatGPT(accessToken: "token", accountID: "account") : .apiKey("key") })
    _ = try await harness.space.fs(.shared).write("/capabilities.json", Data(#"{"image":{"active":"openai","providers":{"openai":{"dialect":"openai-images","baseURL":"https://fake.openai/v1"}}},"web_search":{"active":"brave","providers":{"brave":{"dialect":"brave","baseURL":"https://fake.brave"}}}}"#.utf8), ifMatch: nil)
    let seen = LockIsolated<[String]>([])
    let provider = FetchClient { request in
      seen.withValue { $0.append(request.url.absoluteString) }
      _ = try await request.body?.data()
      return Response(status: .ok, body: .string(request.url.host == "fake.openai" ? #"{"data":[{"b64_json":"\#(routePNG.base64EncodedString())"}]}"# : #"{"web":{"results":[{"title":"Synthetic title","url":"https://example.test","description":"Snippet"}]}}"#))
    }
    let image = try await withDependencies { $0.fetch = provider } operation: {
      try await harness.api(Request(url: URL(string: "http://space/v1/image")!, method: .post, body: try .json(["prompt": "moon"])))
    }
    #expect(image.status == .ok)
    #expect(try await json(image).object?["b64JSON"] == .string(routePNG.base64EncodedString()))
    let search = try await withDependencies { $0.fetch = provider } operation: {
      try await harness.api(Request(url: URL(string: "http://space/v1/web-search")!, method: .post, body: try .json(["query": "moon"])))
    }
    #expect(search.status == .ok)
    #expect(try await json(search).object?["provider"] == .string("brave"))
    #expect(seen.value.count == 2 && seen.value.allSatisfy { !$0.contains("chatgpt") })
  }

  @Test func allNewRoutesStayBehindTheAuthenticationWall() async throws {
    let harness = try Harness(dev: false)
    for path in ["/v1/image", "/v1/web-search"] {
      let response = try await harness.api(Request(url: URL(string: "http://space" + path)!, method: .post, body: .string("{}")))
      #expect(response.status == .unauthorized)
    }
  }
}
