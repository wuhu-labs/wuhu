#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import Serve
import Testing

@Suite struct ServeTests {
  @Test func requestBodyHelpersPreserveBodyConsumptionContract() async throws {
    let body = Body.chunk(Data("hello".utf8))
    var request = Request(url: try #require(URL(string: "http://app.wuhu.test/")), method: .post, body: body)

    #expect(throws: ServeError.unexpectedRequestBody) {
      try request.requireNoBody()
    }

    try await request.discardBody()
    #expect(await body.isResolved)

    request.body = nil
    try request.requireNoBody()
  }

  @Test func requestURLBuildsAbsoluteURLFromOriginForm() throws {
    let url = try Serve.requestURL(
      target: "/runner?x=1",
      method: .get,
      host: "app.wuhu.test",
      options: ServeOptions(),
    )

    #expect(url.absoluteString == "http://app.wuhu.test/runner?x=1")
  }

  @Test func requestURLRejectsInvalidTargets() throws {
    #expect(throws: ServeError.invalidRequestTarget("runner")) {
      _ = try Serve.requestURL(target: "runner", method: .get, host: "app.wuhu.test", options: ServeOptions())
    }

    #expect(throws: ServeError.invalidRequestTarget("/runner#fragment")) {
      _ = try Serve.requestURL(target: "/runner#fragment", method: .get, host: "app.wuhu.test", options: ServeOptions())
    }
  }

  @Test func serveErrorsMapToHTTPStatuses() {
    #expect(ServeError.tooManyHeaders(limit: 1).responseStatus == .requestHeaderFieldsTooLarge)
    #expect(ServeError.requestBodyTooLarge(limit: 1).responseStatus == .contentTooLarge)
    #expect(ServeError.missingHostHeader.responseStatus == .badRequest)
  }

  @Test func responseBodyAllowanceFollowsHTTPStatusClasses() {
    #expect(Serve.responseAllowsBody(.ok))
    #expect(!Serve.responseAllowsBody(Status(code: 101)))
    #expect(!Serve.responseAllowsBody(.noContent))
    #expect(!Serve.responseAllowsBody(.notModified))
  }
}
