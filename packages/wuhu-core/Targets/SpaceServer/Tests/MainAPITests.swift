import Fetch
import Foundation
import Serve
@testable import SpaceServer
import Testing

@Suite struct MainAPITests {
  @Test func aLongLivedBindingServesThousandsOfRequests() async throws {
    let api = MainAPI()
    api.bind { _ in .response(Response(status: .noContent)) }
    let request = Request(url: URL(string: "https://space.test/v1/server")!)
    for _ in 0 ..< 10000 {
      guard case let .response(response) = try await api(request) else { Issue.record("not a response"); return }
      #expect(response.status == .noContent)
    }
  }
}
