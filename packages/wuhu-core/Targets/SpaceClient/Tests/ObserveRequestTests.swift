#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import SpaceClient
import Testing

@Suite struct ObserveRequestTests {
  @Test(arguments: [nil, false, true] as [Bool?]) func batchOptInOnlyChangesGlobRequests(batch: Bool?) async throws {
    let client = SpaceClient(space: "https://space.test", fetch: FetchClient { request in
      let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
      let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
      #expect(components.path == "/v1/observe")
      #expect(query["glob"] == "/notes/**")
      #expect(query["from"] == "7")
      #expect(query["batch"] == (batch == true ? "1" : nil))
      return Response(status: .ok, body: .string(""))
    })
    _ = try await client.observe(ObserveRequest(mode: .glob("/notes/**"), from: 7, batch: batch))
  }

  @Test func sqlDoesNotSendFilesystemBatchFlag() async throws {
    let client = SpaceClient(space: "https://space.test", fetch: FetchClient { request in
      let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
      let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
      #expect(query["sql"] == "SELECT 1")
      #expect(query["batch"] == nil)
      return Response(status: .ok, body: .string(""))
    })
    _ = try await client.observe(ObserveRequest(mode: .sql("SELECT 1"), batch: true))
  }
}
