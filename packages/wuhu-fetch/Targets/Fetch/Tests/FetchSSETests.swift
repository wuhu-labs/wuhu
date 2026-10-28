#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import Fetch
import FetchSSE
import FetchTesting
import Synchronization
import Testing

@Suite struct FetchSSETests {
  @Test func parsesSingleEvent() async throws {
    let response = Response(
      status: Status(code: 200),
      body: .chunk(Data("data: hello\n\n".utf8)),
    )

    let events = try await self.collect(response.sse())

    #expect(events == [SSEEvent(data: "hello")])
  }

  @Test func joinsMultilineDataAndParsesMetadata() async throws {
    let response = Response(
      status: Status(code: 200),
      body: .chunk(
        Data(
          """
          event: update
          id: 123
          retry: 1500
          data: first
          data: second

          """.utf8,
        ),
      ),
    )

    let events = try await self.collect(response.sse())

    #expect(
      events == [
        SSEEvent(event: "update", data: "first\nsecond", id: "123", retry: 1500),
      ],
    )
  }

  @Test func handlesChunkBoundariesAndCRLF() async throws {
    let response = Response(
      status: Status(code: 200),
      body: .chunks([
        Data("event: greet\r".utf8),
        Data("\nid: 42\r\ndata: hel".utf8),
        Data("lo\r\ndata: world\r\n\r\n".utf8),
      ]),
    )

    let events = try await self.collect(response.sse())

    #expect(
      events == [
        SSEEvent(event: "greet", data: "hello\nworld", id: "42"),
      ],
    )
  }

  @Test func ignoresCommentsAndInvalidRetryAndStripsBOM() async throws {
    let response = Response(
      status: Status(code: 200),
      body: .chunk(
        Data([0xEF, 0xBB, 0xBF]) + Data(
          """
          : keepalive
          retry: nope
          data: ok

          """.utf8,
        ),
      ),
    )

    let events = try await self.collect(response.sse())

    #expect(events == [SSEEvent(data: "ok")])
  }

  @Test func carriesLastEventIDForwardAndSupportsEOFDispatch() async throws {
    let response = Response(
      status: Status(code: 200),
      body: .chunk(
        Data(
          """
          id: 42
          data: first

          data: second
          """.utf8,
        ),
      ),
    )

    let events = try await self.collect(response.sse())

    #expect(
      events == [
        SSEEvent(data: "first", id: "42"),
        SSEEvent(data: "second", id: "42"),
      ],
    )
  }

  @Test func skipsEventsWithoutData() async throws {
    let response = Response(
      status: Status(code: 200),
      body: .chunk(
        Data(
          """
          event: noop

          data: yep

          """.utf8,
        ),
      ),
    )

    let events = try await self.collect(response.sse())

    #expect(events == [SSEEvent(data: "yep")])
  }

  @Test func parsesRealHTTPServerSentEvents() async throws {
    let server = try IntegrationServer.start()
    defer { server.stop() }

    let (data, _) = try await URLSession.shared.data(from: server.baseURL.appendingPathComponent("sse"))
    let response = Response(
      status: Status(code: 200),
      body: .chunk(data),
    )

    let events = try await self.collect(response.sse())

    #expect(
      events == [
        SSEEvent(event: "greeting", data: "hello\nworld", id: "42", retry: 1500),
      ],
    )
  }

  @Test func eventsResumeFromTheSentIDAndAnEmptyIDResetsIt() async throws {
    let response = Response(status: Status(code: 200), body: .chunk(Data("data: a\n\nid: 8\ndata: b\n\nid\ndata: c\n\n".utf8)))

    var events: [SSEEvent] = []
    for try await event in response.sseEvents(after: "7") {
      events.append(event)
    }

    #expect(events.map(\.id) == ["7", "8", nil])
  }

  @Test func eventsReadTheBodyNoFasterThanTheyAreTaken() async throws {
    let pulls = Pulls()
    let chunks = (1 ... 3).map { Data("id: \($0)\ndata: x\n\n".utf8) }
    let response = Response(status: Status(code: 200), body: .stream(Counted(chunks: chunks, pulls: pulls)))

    var events = response.sseEvents().makeAsyncIterator()
    #expect(try await events.next()?.id == "1")
    #expect(pulls.count == 1)
    #expect(try await events.next()?.id == "2")
    #expect(pulls.count == 2)
  }

  private func collect(_ events: AsyncThrowingStream<SSEEvent, Error>) async throws -> [SSEEvent] {
    var collected: [SSEEvent] = []

    for try await event in events {
      collected.append(event)
    }

    return collected
  }
}

/// Chunks that count how many were pulled.
private struct Counted: AsyncSequence, Sendable {
  let chunks: [Data]
  let pulls: Pulls

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks[...], pulls: pulls) }

  struct AsyncIterator: AsyncIteratorProtocol {
    var chunks: ArraySlice<Data>
    let pulls: Pulls

    mutating func next() async -> Data? {
      pulls.add()
      return chunks.popFirst()
    }
  }
}

private final class Pulls: Sendable {
  private let pulled = Mutex(0)
  var count: Int { pulled.withLock { $0 } }
  func add() { pulled.withLock { $0 += 1 } }
}
