import Foundation
import PiAI
import Testing
@testable import WuhuCore

struct RemoteSessionSSETransportTests {
  @Test func subscribe_parsesInitialAndEvents() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let initialState = SessionInitialState(
      settings: .init(effectiveModel: .init(provider: .openai, id: "m")),
      status: .init(status: .idle),
      transcriptPages: [
        .init(
          items: [
            .init(
              id: .init(rawValue: "1"),
              createdAt: Date(timeIntervalSince1970: 0),
              entry: .message(.init(author: .unknown, content: .text("hi"))),
            ),
          ],
          nextCursor: nil,
        ),
      ],
      systemUrgent: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )

    let appended = TranscriptItem(
      id: .init(rawValue: "2"),
      createdAt: Date(timeIntervalSince1970: 1),
      entry: .message(.init(author: .unknown, content: .text("yo"))),
    )

    let frames: [SessionSubscriptionSSEFrame] = [
      .initial(initialState),
      .event(.transcriptAppended(.init(items: [appended], nextCursor: nil))),
      .event(.statusUpdated(.init(status: .running))),
    ]

    let http = MockHTTPClient(
      sseHandler: { request in
        #expect(request.url.absoluteString.contains("/v3/sessions/s1/subscribe"))
        #expect(request.headers["Accept"] == "text/event-stream")

        return AsyncThrowingStream { continuation in
          for frame in frames {
            let data = try! WuhuJSON.encoder.encode(frame)
            continuation.yield(.init(data: String(decoding: data, as: UTF8.self)))
          }
          continuation.finish()
        }
      },
    )

    let transport = RemoteSessionSSETransport(baseURL: baseURL, http: http, sleep: { _ in })
    let subscription = try await transport.subscribe(sessionID: .init(rawValue: "s1"), since: .init())

    #expect(subscription.initial == initialState)

    let received = try await Task {
      var it = subscription.events.makeAsyncIterator()
      var out: [SessionEvent] = []
      if let e1 = try await it.next() { out.append(e1) }
      if let e2 = try await it.next() { out.append(e2) }
      return out
    }.value

    #expect(received == [
      .transcriptAppended(.init(items: [appended], nextCursor: nil)),
      .statusUpdated(.init(status: .running)),
    ])
  }

  @Test func subscribe_retriesWithExponentialBackoff_andEmitsConnectionStates() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let initialState = SessionInitialState(
      settings: .init(effectiveModel: .init(provider: .openai, id: "m")),
      status: .init(status: .idle),
      transcriptPages: [],
      systemUrgent: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )

    actor Counter {
      var n = 0
      func next() -> Int {
        n += 1
        return n
      }
    }

    actor SleepRecorder {
      private var delays: [Double] = []
      func record(_ delay: Double) {
        delays.append(delay)
      }

      func values() -> [Double] {
        delays
      }
    }

    let counter = Counter()
    let sleeper = SleepRecorder()

    let http = MockHTTPClient(
      sseHandler: { _ in
        let attempt = await counter.next()
        if attempt <= 2 {
          throw URLError(.notConnectedToInternet)
        }

        return AsyncThrowingStream { continuation in
          let data = try! WuhuJSON.encoder.encode(SessionSubscriptionSSEFrame.initial(initialState))
          continuation.yield(.init(data: String(decoding: data, as: UTF8.self)))
          continuation.onTermination = { _ in
            continuation.finish()
          }
        }
      },
    )

    let transport = RemoteSessionSSETransport(
      baseURL: baseURL,
      http: http,
      retryPolicy: .init(maxDelaySeconds: 30),
      sleep: { seconds in
        await sleeper.record(seconds)
      },
    )

    let subscription = try await transport.subscribe(sessionID: .init(rawValue: "s1"), since: .init())
    #expect(subscription.initial == initialState)

    let states = await Task {
      var it = subscription.connectionStates.makeAsyncIterator()
      var out: [SessionSubscriptionConnectionState] = []
      while out.count < 6, let next = await it.next() {
        out.append(next)
        if next == .connected { break }
      }
      return out
    }.value

    #expect(states.first == .connecting)
    #expect(states.contains(.retrying(attempt: 1, delaySeconds: 0)))
    #expect(states.contains(.retrying(attempt: 2, delaySeconds: 1)))
    #expect(states.contains(.connected))

    let delays = await sleeper.values()
    #expect(delays == [1])
  }

  @Test func enqueue_sendsPOSTWithLaneQueryAndDecodesID() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let expectedID = QueueItemID(rawValue: "q1")

    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v3/sessions/s1/enqueue?lane=followUp")
        #expect(request.headers["Content-Type"] == "application/json")

        let decoded = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: request.body ?? Data())
        #expect(decoded.author == .unknown)
        #expect(decoded.content == .text("hello"))

        let data = try WuhuJSON.encoder.encode(expectedID)
        return (data, HTTPResponse(statusCode: 200))
      },
    )

    let transport = RemoteSessionSSETransport(baseURL: baseURL, http: http)
    let id = try await transport.enqueue(
      sessionID: .init(rawValue: "s1"),
      message: .init(author: .unknown, content: .text("hello")),
      lane: .followUp,
    )

    #expect(id == expectedID)
  }

  @Test func cancel_sendsPOSTWithLaneQuery() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v3/sessions/s1/cancel?lane=steer")

        struct Body: Decodable { var id: QueueItemID }
        let decoded = try WuhuJSON.decoder.decode(Body.self, from: request.body ?? Data())
        #expect(decoded.id == .init(rawValue: "q1"))

        return (Data(), HTTPResponse(statusCode: 200))
      },
    )

    let transport = RemoteSessionSSETransport(baseURL: baseURL, http: http)
    try await transport.cancel(
      sessionID: .init(rawValue: "s1"),
      id: .init(rawValue: "q1"),
      lane: .steer,
    )
  }
}

private struct MockHTTPClient: HTTPClient {
  var dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))?
  var sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)?

  init(
    dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))? = nil,
    sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)? = nil,
  ) {
    self.dataHandler = dataHandler
    self.sseHandler = sseHandler
  }

  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    guard let dataHandler else {
      throw PiAIError.unsupported("MockHTTPClient.dataHandler not set")
    }
    return try await dataHandler(request)
  }

  func sse(for request: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    guard let sseHandler else {
      throw PiAIError.unsupported("MockHTTPClient.sseHandler not set")
    }
    return try await sseHandler(request)
  }
}
