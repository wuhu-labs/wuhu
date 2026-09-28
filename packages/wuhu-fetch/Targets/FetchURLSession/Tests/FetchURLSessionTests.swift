import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import Fetch
import FetchSSE
import FetchTesting
import FetchURLSession
import Testing

@Suite struct FetchURLSessionTests {
  @Test func roundTripsMethodHeadersAndBody() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    var headers = Headers()
    headers[.userAgent] = "fetch-tests"
    headers[.contentType] = "text/plain; charset=utf-8"

    let request = Request(
      url: server.baseURL.appendingPathComponent("echo"),
      method: .post,
      headers: headers,
      body: .string("hello"),
    )

    let response = try await FetchClient
      .urlSession(URLSession(configuration: .ephemeral))(request)
      .validateStatus()

    let payload = try await response.json(EchoPayload.self)

    #expect(payload.method == "POST")
    #expect(payload.path == "/echo")
    #expect(payload.body == "hello")
    #expect(payload.header(named: "user-agent") == "fetch-tests")
    #expect(payload.header(named: "content-type")?.contains("text/plain") == true)
  }

  @Test func mapsStatusAndBody() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    let request = Request(url: server.baseURL.appendingPathComponent("status/418"))
    let response = try await FetchClient.urlSession(URLSession(configuration: .ephemeral))(request)

    #expect(response.status.code == 418)
    #expect(try await response.text() == "status:418")
  }

  @Test func streamsServerSentEventsIncrementally() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    var components = URLComponents(
      url: server.baseURL.appendingPathComponent("sse-gated"),
      resolvingAgainstBaseURL: false,
    )
    let streamID = UUID().uuidString
    components?.queryItems = [
      URLQueryItem(name: "id", value: streamID),
    ]

    let fetch = FetchClient.urlSession(URLSession(configuration: .ephemeral))
    let request = Request(url: try #require(components?.url))
    let response = try await fetch(request)
    var events = response.sse().makeAsyncIterator()

    let firstEvent = try await events.next()

    var releaseComponents = URLComponents(
      url: server.baseURL.appendingPathComponent("release-sse"),
      resolvingAgainstBaseURL: false,
    )
    releaseComponents?.queryItems = [
      URLQueryItem(name: "id", value: streamID),
    ]
    _ = try await fetch(Request(url: try #require(releaseComponents?.url))).validateStatus()

    let secondEvent = try await events.next()

    #expect(firstEvent == SSEEvent(event: "greeting", data: "first", id: "1"))
    #expect(secondEvent == SSEEvent(event: "greeting", data: "second", id: "2"))
    #expect(try await events.next() == nil)
  }

  @Test func reusesClientForConcurrentRequests() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    let fetch = FetchClient.urlSession(URLSession(configuration: .ephemeral))
    let baseURL = server.baseURL

    let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
      for status in [200, 201, 202, 418] {
        group.addTask {
          let response = try await fetch(
            Request(url: baseURL.appendingPathComponent("status/\(status)")),
          )
          #expect(try await response.text() == "status:\(status)")
          return response.status.code
        }
      }

      var statuses: [Int] = []
      for try await status in group {
        statuses.append(status)
      }
      return statuses.sorted()
    }

    #expect(statuses == [200, 201, 202, 418])
  }
}

private struct EchoPayload: Decodable {
  var method: String
  var path: String
  var headers: [String: String]
  var body: String

  func header(named name: String) -> String? {
    self.headers.first { key, _ in
      key.caseInsensitiveCompare(name) == .orderedSame
    }?.value
  }
}
