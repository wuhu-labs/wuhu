#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import ServeRouting
import Testing

@Suite struct ServeRoutingTests {
  @Test func exactMethodAndPathMatch() async throws {
    var router = Router()
    router.get("/healthz") { _, _ in
      Response(status: .ok, body: .string("ok"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/healthz"))),
    )

    #expect(response.status == .ok)
    #expect(try await response.body.text() == "ok")
  }

  @Test func routeParametersAreExtracted() async throws {
    var router = Router()
    router.get("/v1/runners/:name") { _, parameters in
      Response(status: .ok, body: .string(parameters["name"] ?? ""))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/runners/mac-mini"))),
    )

    #expect(response.status == .ok)
    #expect(try await response.body.text() == "mac-mini")
  }

  @Test func prefixMountCopiesChildRoutes() async throws {
    var child = Router()
    child.get("/status") { _, _ in
      Response(status: .accepted, body: .string("runner"))
    }

    var router = Router()
    router.mount("/v1/runner", child)

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/runner/status"))),
    )

    #expect(response.status == .accepted)
    #expect(try await response.body.text() == "runner")
  }

  @Test func missingRouteReturnsNotFound() async throws {
    var router = Router()
    router.get("/healthz") { _, _ in
      Response(status: .ok)
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/missing"))),
    )

    #expect(response.status == .notFound)
    #expect(try await response.body.text() == "404 Not Found\n")
  }

  @Test func wrongMethodReturnsMethodNotAllowedWithAllowHeader() async throws {
    var router = Router()
    router.get("/v1/bash") { _, _ in
      Response(status: .ok)
    }
    router.post("/v1/bash") { _, _ in
      Response(status: .accepted)
    }

    let response = try await router.handler(
      Request(
        url: try #require(URL(string: "http://localhost/v1/bash")),
        method: .delete,
      ),
    )

    #expect(response.status == .methodNotAllowed)
    #expect(response.headers[.allow] == "GET, POST")
    #expect(try await response.body.text() == "405 Method Not Allowed\n")
  }

  @Test func moreSpecificStaticRouteWinsOverParameterizedRoute() async throws {
    var router = Router()
    router.get("/v1/runners/:name") { _, parameters in
      Response(status: .ok, body: .string("param:\(parameters["name"] ?? "")"))
    }
    router.get("/v1/runners/local") { _, _ in
      Response(status: .ok, body: .string("static"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/runners/local"))),
    )

    #expect(response.status == .ok)
    #expect(try await response.body.text() == "static")
  }

  @Test func trailingSlashUsesSameNormalizedPath() async throws {
    var router = Router()
    router.get("/v1/runners") { _, _ in
      Response(status: .ok, body: .string("normalized"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/runners/"))),
    )

    #expect(response.status == .ok)
    #expect(try await response.body.text() == "normalized")
  }

  @Test func catchAllRouteMatchesNestedAndEmptySuffixes() async throws {
    var router = Router()
    router.get("/v1/space/*") { request, _ in
      Response(status: .ok, body: .string(request.url.path))
    }

    let nested = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/space/read-text"))),
    )
    let empty = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/space"))),
    )

    #expect(nested.status == .ok)
    #expect(try await nested.body.text() == "/v1/space/read-text")
    #expect(empty.status == .ok)
    #expect(try await empty.body.text() == "/v1/space")
  }

  @Test func exactRouteWinsOverCatchAllRoute() async throws {
    var router = Router()
    router.get("/v1/space/*") { _, _ in
      Response(status: .ok, body: .string("catch-all"))
    }
    router.get("/v1/space/query") { _, _ in
      Response(status: .ok, body: .string("exact"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/space/query"))),
    )

    #expect(response.status == .ok)
    #expect(try await response.body.text() == "exact")
  }

  @Test func middlewareWrapsRouteHandlerInRegistrationOrder() async throws {
    var router = Router()
    router.use { next in
      { request in
        var response = try await next(request)
        response.headers[.init("x-order")!] = "outer"
        return response
      }
    }
    router.use { next in
      { request in
        var response = try await next(request)
        response.headers[.init("x-inner")!] = "inner"
        return response
      }
    }
    router.get("/healthz") { _, _ in
      Response(status: .ok, body: .string("ok"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/healthz"))),
    )

    #expect(response.status == .ok)
    #expect(response.headers[.init("x-order")!] == "outer")
    #expect(response.headers[.init("x-inner")!] == "inner")
  }

  @Test func encodedLiteralSegmentMatchesDecodedLiteral() async throws {
    var router = Router()
    router.get("/healthz") { _, _ in
      Response(status: .ok, body: .string("ok"))
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/health%7A"))),
    )
    #expect(response.status == .ok)
    #expect(try await response.body.text() == "ok")
  }

  @Test func parameterIsDecodedWhileRawIsPreserved() async throws {
    var router = Router()
    router.get("/users/:name") { _, parameters in
      var response = Response(status: .ok, body: .string(parameters["name"] ?? ""))
      response.headers[.init("x-raw")!] = parameters.rawValues["name"] ?? ""
      return response
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/users/a%20b"))),
    )
    #expect(try await response.body.text() == "a b")
    #expect(response.headers[.init("x-raw")!] == "a%20b")
  }

  @Test func singleSegmentParameterCarriesEncodedSlashRaw() async throws {
    var router = Router()
    router.get("/v1/fs/:path") { _, parameters in
      var response = Response(status: .ok, body: .string(parameters["path"] ?? ""))
      response.headers[.init("x-raw")!] = parameters.rawValues["path"] ?? ""
      return response
    }

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/fs/abc%2Fdef.md"))),
    )
    #expect(try await response.body.text() == "abc/def.md")
    #expect(response.headers[.init("x-raw")!] == "abc%2Fdef.md")
  }

  @Test func mountedRouterPreservesItsMiddlewareForMountedRoutes() async throws {
    var child = Router()
    child.use { next in
      { request in
        var response = try await next(request)
        response.headers[.init("x-child")!] = "present"
        return response
      }
    }
    child.get("/status") { _, _ in
      Response(status: .ok, body: .string("child"))
    }

    var router = Router()
    router.mount("/v1/runner", child)

    let response = try await router.handler(
      Request(url: try #require(URL(string: "http://localhost/v1/runner/status"))),
    )

    #expect(response.status == .ok)
    #expect(response.headers[.init("x-child")!] == "present")
    #expect(try await response.body.text() == "child")
  }
}
