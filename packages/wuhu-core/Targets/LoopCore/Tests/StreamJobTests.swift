import ControlledTime
import Dependencies
import Fetch
import Foundation
import GRDB
@testable import LoopCore
import MainHub
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing

/// An event stream behind a fetch client. Each dial is recorded and answered by `answer`; nil opens a stream the test writes to.
private final class EventServer: Sendable {
  struct Dial: Sendable {
    let lastEventID: String?
    let stream: AsyncThrowingStream<Data, any Error>.Continuation
  }

  private let log = Mutex<[Dial]>([])
  private let answer: @Sendable (Int) -> Response?

  init(answer: @escaping @Sendable (Int) -> Response? = { _ in nil }) {
    self.answer = answer
  }

  var dials: [Dial] { log.withLock { $0 } }

  var sources: EventSources {
    EventSources(token: { _, _ in "stream-token" }, fetch: FetchClient { self.respond($0) })
  }

  private func respond(_ request: Request) -> Response {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    let index = log.withLock {
      $0.append(Dial(lastEventID: request.headers["Last-Event-ID"], stream: continuation))
      return $0.count - 1
    }
    if let answered = answer(index) {
      continuation.finish()
      return answered
    }
    return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .stream(contentType: "text/event-stream", stream))
  }

  /// Writes `text` on dial `index`; false once that connection is gone.
  @discardableResult
  func send(_ text: String, on index: Int) -> Bool {
    if case .terminated = dials[index].stream.yield(Data(text.utf8)) { return false }
    return true
  }
}

private let url = URL(string: "https://events.example/stream")!
private let observation = SubscriptionID("obs.c1")

private func streaming(
  _ events: EventServer,
  replies: [String] = [],
  _ body: (Space, SessionID, SessionExecution, TimeControl) async throws -> Void,
) async throws {
  try await withKernelDeps { time in
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
    let script = InferenceScript(replies.map { Fix.replying($0) })
    var config = makeConfig(inference: { try await script($0) })
    config.sources = events.sources
    let execution = SessionExecution(space: space, loopConfig: config)
    execution.start()
    do {
      try await body(space, session, execution, time)
    } catch {
      await execution.shutdown()
      throw error
    }
    await execution.shutdown()
  }
}

private func observed(_ space: Space, _ session: SessionID) async throws -> [SystemNotification] {
  try await space.sessions.hydrate(session).transcript.kernel.items.compactMap { item in
    guard case let .notification(notice) = item, notice.kind == .spaceObservation else { return nil }
    return notice
  }
}

private func cursor(_ space: Space) async throws -> String? {
  try await space.sessions.writer.read { db in try String.fetchOne(db, sql: "SELECT last_event_id FROM streams") }
}

@Suite struct StreamJobTests {
  @Test func `events wait on their topic for the throttle and a new dial resumes after the last one taken`() async throws {
    let events = EventServer()
    try await streaming(events, replies: ["one", "two"]) { space, session, execution, time in
      try await space.sessions.stream(session, observation, url: url, throttleSeconds: 30)
      try await until("first dial") { events.dials.count == 1 }
      let listed = try await space.query("SELECT id, url FROM subscriptions", as: space.principal(of: session))
      #expect(listed.rows == [[.text(observation.rawValue), .text(url.absoluteString)]])
      events.send("id: 1\ndata: one\n\n", on: 0)
      try await until("first wake") { try await observed(space, session).count == 1 }
      events.send("id: 2\nevent: build\ndata: two\n\nid: 3\ndata: three\ndata: lines\n\n", on: 0)
      try await until("both taken") { try await cursor(space) == "3" }
      #expect(try await observed(space, session).count == 1)
      try await until("second wake") {
        await time.advance(by: 30)
        return try await observed(space, session).count == 2
      }
      #expect(try await observed(space, session).map(\.content.text) == [
        "observed events from \(url):\nid: 1\ndata: one\n\n",
        "observed events from \(url):\nid: 2\nevent: build\ndata: two\n\nid: 3\ndata: three\ndata: lines\n\n",
      ])
      events.dials[0].stream.finish()
      try await until("second dial") {
        await time.advance(by: 1)
        return events.dials.count == 2
      }
      #expect(events.dials.map(\.lastEventID) == [nil, "3"])
    }
  }

  @Test func `a refused stream says why once and ends`() async throws {
    let events = EventServer { _ in Response(status: .notFound) }
    try await streaming(events, replies: ["seen"]) { space, session, execution, _ in
      try await space.sessions.stream(session, observation, url: url, throttleSeconds: 0)
      try await until("the ending wakes the session") { try await observed(space, session).count == 1 }
      let ending = try await observed(space, session)[0]
      #expect(ending.content.text == "observation \(observation.rawValue) of \(url) failed and was cancelled: \(url) answered HTTP 404")
      #expect(ending.endsSubscription)
      #expect(try await cursor(space) == nil)
      #expect(events.dials.count == 1)
    }
  }

  @Test func `unstreaming closes the connection and unlists the stream`() async throws {
    let events = EventServer()
    try await streaming(events) { space, session, execution, _ in
      try await space.sessions.stream(session, observation, url: url, throttleSeconds: 0)
      try await until("first dial") { events.dials.count == 1 }
      _ = try await space.sessions.cancelSubscription(session, subscriptionID: observation, answering: ToolCallID("cancel")) { _ in
        .cancelObservation(.init(subscriptionID: observation))
      }
      try await until("the connection closes") { !events.send(": ping\n\n", on: 0) }
      try await until("unlisted") { try await space.query("SELECT id FROM subscriptions", as: space.principal(of: session)).rows.isEmpty }
      #expect(events.dials.count == 1)
    }
  }
}
