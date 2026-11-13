import ControlledTime
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import MainHub
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing

/// An event stream behind a fetch client. Each dial is recorded and answered by `answer`; nil opens a stream the test writes to.
final class EventServer: Sendable {
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
    let script = InferenceScript(replies.map { Fix.replying($0) })
    var config = makeConfig(inference: { try await script($0) })
    config.sources = events.sources
    let execution = SessionExecution(space: space, loopConfig: config)
    let session = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
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

private func observed(_ space: Space, _ session: SessionID) async throws -> [TranscriptLine] {
  try await space.sessions.lines(session).filter { $0.key == "subscription:\(observation.rawValue)" }
}

private func cursor(_ space: Space, _ session: SessionID) async throws -> String? {
  space.worker.job(StreamJob.ID("\(session.rawValue):\(observation.rawValue)")).db.rows(StreamRow.all).first?.lastEventID
}

@Suite struct StreamJobTests {
  @Test func `events wait on their topic for the throttle and a new dial resumes after the last one taken`() async throws {
    let events = EventServer()
    try await streaming(events, replies: ["one", "two"]) { space, session, execution, time in
      _ = try await execution.arm(session, Arming(.init(id: observation, kind: .stream(url: url, throttleSeconds: 30))))
      try await until("first dial") { events.dials.count == 1 }
      let listed = try await space.query("SELECT id, url FROM subscriptions", as: space.principal(of: session))
      #expect(listed.rows == [[.text(observation.rawValue), .text(url.absoluteString)]])
      events.send("id: 1\ndata: one\n\n", on: 0)
      try await until("first wake") { try await observed(space, session).count == 1 }
      events.send("id: 2\nevent: build\ndata: two\n\nid: 3\ndata: three\ndata: lines\n\n", on: 0)
      try await until("both taken") { try await cursor(space, session) == "3" }
      #expect(try await observed(space, session).count == 1)
      // The second notice is a queued input due one throttle (30 s) after it was put, and the cell drains it at the wake that comes
      // next: bounded ticks past the throttle, never one per poll (see `until`), with one worker here so no lease lapses.
      try await untilAdvancing("second wake", time, attempts: 40) { try await observed(space, session).count == 2 }
      let notices = try await observed(space, session)
      let expected = [
        "observed events from \(url):\nid: 1\ndata: one\n\n",
        "observed events from \(url):\nid: 2\nevent: build\ndata: two\n\nid: 3\ndata: three\ndata: lines\n\n",
      ]
      #expect(notices.count == expected.count)
      for (notice, text) in zip(notices, expected) {
        #expect(notice.text.hasSuffix("\n\n" + text))
      }
      events.dials[0].stream.finish()
      // The job backs off a second of the injected clock before it dials again, and that backoff is armed only once it notices the
      // stream ended: bounded ticks, never one per poll (see `until`), with one worker here so no lease lapses.
      try await untilAdvancing("second dial", time, attempts: 25) { events.dials.count == 2 }
      #expect(events.dials.map(\.lastEventID) == [nil, "3"])
    }
  }

  @Test func `a refused stream says why once and ends`() async throws {
    let events = EventServer { _ in Response(status: .notFound) }
    try await streaming(events, replies: ["seen"]) { space, session, execution, _ in
      _ = try await execution.arm(session, Arming(.init(id: observation, kind: .stream(url: url, throttleSeconds: 0))))
      try await until("the ending wakes the session") { try await observed(space, session).count == 1 }
      let ending = try await observed(space, session)[0]
      #expect(ending.text.hasSuffix("\n\nobservation \(observation.rawValue) of \(url) failed and was cancelled: \(url) answered HTTP 404"))
      #expect(try await space.query("SELECT id FROM subscriptions", as: space.principal(of: session)).rows.isEmpty)
      #expect(try await cursor(space, session) == nil)
      #expect(events.dials.count == 1)
    }
  }

  @Test func `unstreaming closes the connection and unlists the stream`() async throws {
    let events = EventServer()
    try await streaming(events) { space, session, execution, _ in
      _ = try await execution.arm(session, Arming(.init(id: observation, kind: .stream(url: url, throttleSeconds: 0))))
      try await until("first dial") { events.dials.count == 1 }
      #expect(try await execution.disarm(session, observation) == .cancelObservation(.init(subscriptionID: observation)))
      try await until("the connection closes") { !events.send(": ping\n\n", on: 0) }
      try await until("unlisted") { try await space.query("SELECT id FROM subscriptions", as: space.principal(of: session)).rows.isEmpty }
      #expect(events.dials.count == 1)
    }
  }
}
