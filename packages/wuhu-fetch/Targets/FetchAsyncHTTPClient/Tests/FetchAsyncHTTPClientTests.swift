#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import FetchTesting
import Testing

@Suite struct FetchAsyncHTTPClientTests {
  @Test func roundTripsMethodHeadersAndBody() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    try await withHTTPClient { client in
      var headers = Headers()
      headers[.userAgent] = "fetch-tests"
      headers[.contentType] = "text/plain; charset=utf-8"

      let request = Request(
        url: server.baseURL.appendingPathComponent("echo"),
        method: .post,
        headers: headers,
        body: .string("hello"),
      )

      let response = try await FetchClient.asyncHTTPClient(client)(request).validateStatus()
      let payload = try await response.json(EchoPayload.self)

      #expect(payload.method == "POST")
      #expect(payload.path == "/echo")
      #expect(payload.body == "hello")
      #expect(payload.header(named: "user-agent") == "fetch-tests")
      #expect(payload.header(named: "content-type")?.contains("text/plain") == true)
    }
  }

  @Test func mapsStatusAndBody() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    try await withHTTPClient { client in
      let request = Request(url: server.baseURL.appendingPathComponent("status/418"))
      let response = try await FetchClient.asyncHTTPClient(client)(request)

      #expect(response.status.code == 418)
      #expect(try await response.text() == "status:418")
    }
  }

  @Test func bufferedBodiesSurviveAnEarlyErrorBeforeRequestStreamCompletion() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }
    try await withHTTPClient { client in
      let fetch = FetchClient.asyncHTTPClient(client)
      for _ in 0 ..< 100 {
        for body in [Body.empty, try Body.json(["value": "refused"]), Body.chunks([Data("one".utf8), Data("two".utf8)])] {
          let response = try await fetch(Request(url: server.baseURL.appendingPathComponent("early-error"), method: .post, body: body))
          #expect(response.status.code == 400)
          #expect(try await response.text() == "!")
          #expect(await body.isResolved)
        }
      }
    }
  }

  @Test func largeBufferedBodiesSurviveAnEarlyErrorWithoutBecomingStreams() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }
    try await withHTTPClient { client in
      let fetch = FetchClient.asyncHTTPClient(client)
      for _ in 0 ..< 10 {
        let body = Body.bytes(Data(repeating: 0x61, count: 4 * 1024 * 1024 + 1))
        let response = try await fetch(Request(url: server.baseURL.appendingPathComponent("early-error"), method: .post, body: body))
        #expect(response.status.code == 400)
        #expect(try await response.text() == "!")
        #expect(await body.isResolved)
      }
    }
  }

  // An error head pauses a stream-backed upload; it does not cancel it. The
  // fixture sends the 400 head only after the first chunk, so the client is
  // already waiting on the stream, not on a paused write, when it finishes.
  // The fixture answers "!" only once the terminating chunk arrives, and the
  // client sends that chunk from requestStreamFinished, so a "!" proves the
  // stream finished after the 400 head and before the response end.
  @Test func streamedBodiesMayFinishAfterAnEarlyErrorHead() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }
    try await withHTTPClient { client in
      let fetch = FetchClient.asyncHTTPClient(client)
      for _ in 0 ..< 20 {
        let (chunks, producer) = AsyncStream<Bytes>.makeStream()
        producer.yield(Bytes("one".utf8))
        let request = Request(url: server.baseURL.appendingPathComponent("error-after-first-chunk"), method: .post, body: .stream(chunks))
        let response = try await fetch(request)
        #expect(response.status.code == 400)
        producer.finish()
        #expect(try await response.text() == "!")
      }
    }
  }

  @Test func bufferedBodiesStillValidateDeclaredLength() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }
    try await withHTTPClient { client in
      var body = Body.string("short")
      body.contentLength = 99
      await #expect(throws: HTTPClientError.bodyLengthMismatch) {
        try await FetchClient.asyncHTTPClient(client)(Request(url: server.baseURL.appendingPathComponent("echo"), method: .post, body: body))
      }
    }
  }

  @Test func acceptsNoTimeout() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    try await withHTTPClient { client in
      let response = try await FetchClient.asyncHTTPClient(client, timeout: nil)(
        Request(url: server.baseURL.appendingPathComponent("status/204")),
      )
      #expect(response.status.code == 204)
    }
  }
}

private func withHTTPClient(
  _ operation: (HTTPClient) async throws -> Void,
) async throws {
  var configuration = HTTPClient.Configuration()
  configuration.enableHTTP2HealthChecks()
  let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  do {
    try await operation(client)
    try await client.shutdown()
  } catch {
    try? await client.shutdown()
    throw error
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
