#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import DependenciesTestSupport
import Fetch
import HTTPTypes
import Testing

@Suite struct FetchTests {
  @Test func requestHeadersSeparateNormalAndSensitiveValues() throws {
    var headers = RequestHeaders(values: ["Content-Type": "application/json"])

    headers.setSensitive("Authorization", "Bearer secret")

    #expect(headers.values == ["content-type": "application/json"])
    #expect(headers.sensitiveValues == ["authorization": "Bearer secret"])
    #expect(headers["Content-Type"] == "application/json")
    #expect(headers["Authorization"] == nil)
    #expect(headers.fields[.contentType] == "application/json")
    #expect(headers.fields[.authorization] == nil)

    headers.set("Authorization", "public")

    #expect(headers.values["authorization"] == "public")
    #expect(headers.sensitiveValues["authorization"] == nil)
  }

  @Test func repeatedFieldsFoldIntoOneValue() throws {
    var fields = Headers()
    fields.append(HTTPField(name: .cookie, value: "a=1"))
    fields.append(HTTPField(name: .cookie, value: "b=2"))
    fields.append(HTTPField(name: .accept, value: "text/html"))
    fields.append(HTTPField(name: .accept, value: "*/*"))

    let headers = RequestHeaders(fields)

    #expect(headers[.cookie] == "a=1; b=2")
    #expect(headers[.accept] == "text/html, */*")
  }

  @Test func requestHeadersMergePreservesSensitivity() throws {
    var base = RequestHeaders(values: ["Accept": "application/json"])
    let override = RequestHeaders(
      values: ["X-Trace": "trace"],
      sensitiveValues: ["X-Api-Key": "secret"],
    )

    base.merge(override)

    #expect(base.values == ["accept": "application/json", "x-trace": "trace"])
    #expect(base.sensitiveValues == ["x-api-key": "secret"])
  }

  @Test func requestStringBody() async throws {
    let body = Body.string("hello")
    let response = Response(status: .ok, body: body)

    #expect(body.contentType == "text/plain; charset=utf-8")
    #expect(try await response.text() == "hello")
  }

  @Test func requestJSONBody() async throws {
    struct Payload: Codable, Equatable {
      var message: String
    }

    let body = try Body.json(Payload(message: "hi"))
    let response = Response(status: .ok, body: body)

    #expect(body.contentType == "application/json")
    #expect(try await response.json(Payload.self) == Payload(message: "hi"))
  }

  @Test func responseJSONBuildsHeadersAndUsesStableDefaults() async throws {
    let response = try Response.json(["b": 2, "a": 1], status: .created)

    #expect(response.status == .created)
    #expect(response.headers[.contentType] == "application/json")
    #expect(response.headers[.contentLength] == "13")
    #expect(try await response.text() == #"{"a":1,"b":2}"#)
  }

  @Test func responseTextBuildsHeaders() async throws {
    let response = Response.text("hello", status: .accepted)

    #expect(response.status == .accepted)
    #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
    #expect(response.headers[.contentLength] == "5")
    #expect(try await response.text() == "hello")
  }

  @Test func requestJSONDecodesBody() async throws {
    struct Payload: Decodable, Equatable {
      var date: Date
    }

    let request = Request(
      url: URL(string: "https://example.com")!,
      method: .post,
      body: .bytes(Data(#"{"date":1}"#.utf8), contentType: "application/json"),
    )

    #expect(try await request.json(Payload.self) == Payload(date: Date(timeIntervalSince1970: 1)))
  }

  @Test func validatesStatus() throws {
    let ok = Response(status: .ok)
    let created = Response(status: .created)
    let badRequest = Response(status: .badRequest)

    #expect(try ok.validateStatus().status == .ok)
    #expect(try created.validateStatus(200 ..< 400).status == .created)

    do {
      _ = try badRequest.validateStatus()
      Issue.record("Expected unexpected status error")
    } catch let error as FetchError {
      guard case let .unexpectedStatus(status) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(status == .badRequest)
    }
  }

  @Test func enforcesBodyLimit() async throws {
    let response = Response(status: .ok, body: .chunks([Data([1, 2]), Data([3, 4])]))

    do {
      _ = try await response.bytes(upTo: 3)
      Issue.record("Expected body limit error")
    } catch let error as FetchError {
      guard case let .bodyLimitExceeded(limit) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(limit == 3)
    }
  }

  @Test func usesDependencyKey() async throws {
    let request = Request(url: URL(string: "https://example.com")!)

    let response = try await withDependencies {
      $0.fetch = FetchClient { request in
        #expect(request.url.absoluteString == "https://example.com")
        return Response(status: .ok, body: .chunk(Data("value".utf8)))
      }
    } operation: {
      @Dependency(\.fetch) var fetch
      return try await fetch(request)
    }

    #expect(try await response.text() == "value")
  }

  @Test func inMemoryBodiesAreReplayable() async throws {
    let body = Body.string("hello")

    #expect(body.isReplayable)
    #expect(try await body.text() == "hello")

    let replay = try #require(body.replay())
    #expect(try await replay.text() == "hello")
  }

  @Test func asyncBytesConsumesBodyOnce() async throws {
    let body = Body.chunk(Data([1, 2, 3]))

    var chunks: [Bytes] = []
    for try await chunk in body.asyncBytes() {
      chunks.append(chunk)
    }

    #expect(chunks == [Data([1, 2, 3])])

    do {
      _ = try await body.bytes()
      Issue.record("Expected bodyAlreadyConsumed")
    } catch let error as FetchError {
      #expect(error == .bodyAlreadyConsumed)
    }
  }
}
