#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import Serve
import ServeTesting
import Testing

@Suite
struct ServeTestingTests {
  @Test func passesResponseThrough() async throws {
    let handler: Handler = { request in Response(status: .ok, body: .string("hello \(request.url.path)")) }
    let client = ServeTesting.client(handler)
    let response = try await client(Request(url: URL(string: "http://space/greet")!))
    #expect(response.status == .ok)
    #expect(try await response.body.text() == "hello /greet")
  }

  @Test func streamsResponseBodyWithoutBuffering() async throws {
    // "b" is yielded only after the caller has consumed "a", so a client that
    // drained the body before returning the Response would deadlock here.
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.yield(Data("a".utf8))
    let handler: Handler = { _ in
      Response(status: .ok, body: .stream(contentType: "text/plain", stream))
    }
    let client = ServeTesting.client(handler)
    let response = try await client(Request(url: URL(string: "http://space/stream")!))
    #expect(response.body.contentLength == nil)
    var iterator = response.body.asyncBytes().makeAsyncIterator()
    let first = try await iterator.next()
    #expect(first.map { String(decoding: $0, as: UTF8.self) } == "a")
    continuation.yield(Data("b".utf8))
    continuation.finish()
    let second = try await iterator.next()
    #expect(second.map { String(decoding: $0, as: UTF8.self) } == "b")
    #expect(try await iterator.next() == nil)
  }

  @Test func mapsServeErrorToStatus() async throws {
    let handler: Handler = { _ in throw ServeError.requestBodyTooLarge(limit: 10) }
    let client = ServeTesting.client(handler)
    let response = try await client(Request(url: URL(string: "http://space")!))
    #expect(response.status == .contentTooLarge)
    let body = try await response.body.text()
    #expect(body.hasPrefix("413 "))
    #expect(body.hasSuffix("\n"))
  }

  @Test func propagatesNonServeErrors() async throws {
    struct Boom: Error {}
    let handler: Handler = { _ in throw Boom() }
    let client = ServeTesting.client(handler)
    await #expect(throws: Boom.self) {
      _ = try await client(Request(url: URL(string: "http://space")!))
    }
  }

  @Test func foldsSensitiveHeadersOntoTheWire() async throws {
    let handler: Handler = { request in Response(status: .ok, body: .string(request.headers[.authorization] ?? "none")) }
    let client = ServeTesting.client(handler)
    var request = Request(url: URL(string: "http://space")!)
    request.headers.setSensitive(.authorization, "Bearer secret")
    let response = try await client(request)
    #expect(try await response.body.text() == "Bearer secret")
  }

  @Test func refusesUpgradeThroughTheClient() async throws {
    let handler: UpgradingHandler = { _ in .webSocket { _ in } }
    let client = ServeTesting.client(upgrading: handler)
    await #expect(throws: WebSocketUpgradeRefused.self) {
      _ = try await client(Request(url: URL(string: "http://space/ws")!))
    }
  }

  @Test func drivesAnInMemoryWebSocketSession() async throws {
    let handler: UpgradingHandler = { _ in
      .webSocket { socket in
        for await message in socket.inbound {
          if case let .text(text) = message {
            try? await socket.send(.text("echo:\(text)"))
          }
        }
      }
    }
    guard case let .webSocket(socket, serve) = try await ServeTesting.upgrade(handler, Request(url: URL(string: "http://space/ws")!)) else {
      Issue.record("expected a websocket upgrade")
      return
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await serve() }
      try await socket.send(.text("ping"))
      var iterator = socket.inbound.makeAsyncIterator()
      let reply = await iterator.next()
      #expect(reply == .text("echo:ping"))
      socket.close()
      try await group.waitForAll()
    }
  }

  @Test func mapsServeErrorToResponseThroughUpgrade() async throws {
    let handler: UpgradingHandler = { _ in throw ServeError.missingHostHeader }
    guard case let .response(response) = try await ServeTesting.upgrade(handler, Request(url: URL(string: "http://space/ws")!)) else {
      Issue.record("expected an error response, not an upgrade")
      return
    }
    #expect(response.status == .badRequest)
    #expect(try await response.body.text().hasPrefix("400 "))
  }

  @Test func returnsResponseForNonUpgradeThroughUpgrade() async throws {
    let handler: UpgradingHandler = { _ in .response(Response(status: .accepted)) }
    guard case let .response(response) = try await ServeTesting.upgrade(handler, Request(url: URL(string: "http://space")!)) else {
      Issue.record("expected a response")
      return
    }
    #expect(response.status == .accepted)
  }
}
