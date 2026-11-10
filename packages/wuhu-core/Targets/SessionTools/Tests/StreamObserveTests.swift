import AsyncHTTPClient
import Dependencies
import DeterministicDependencies
import Fetch
import FetchAsyncHTTPClient
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import MainHub
import ServeNIO
import SessionDomain
@testable import SessionTools
import struct SpaceContract.GroupID
import struct SpaceContract.ObserverInput
import struct SpaceContract.SubscriptionObserveInput
@_spi(SessionObservation) import SpaceCore
import Synchronization
import Testing

/// A local event stream. Each dial is recorded and answered by `answer`; nil
/// opens a stream the test writes to.
final class EventServer: Sendable {
  struct Dial: Sendable {
    let lastEventID: String?
    let stream: AsyncThrowingStream<Bytes, any Error>.Continuation
  }

  private let log = Mutex<[Dial]>([])
  private let answer: @Sendable (Int) -> Response?

  init(answer: @escaping @Sendable (Int) -> Response? = { _ in nil }) {
    self.answer = answer
  }

  var dials: [Dial] { log.withLock { $0 } }

  func respond(_ request: Request) -> Response {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Bytes.self, throwing: (any Error).self)
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

func withEventServer(_ events: EventServer, _ body: (URL, EventSources) async throws -> Void) async throws {
  let server = try await ServeNIOServer.bind(port: 0, handler: { events.respond($0) })
  let client = HTTPClient(eventLoopGroupProvider: .singleton)
  let url = URL(string: "http://127.0.0.1:\(server.localAddress!.port!)/events")!
  let sources = EventSources(token: { _, _ in "stream-token" }, fetch: .asyncHTTPClient(client, timeout: nil))
  do {
    try await body(url, sources)
  } catch {
    try await client.shutdown()
    await server.shutdown()
    throw error
  }
  try await client.shutdown()
  await server.shutdown()
}

private let recording = """
import {readText, writeText} from 'wuhu:space';
export default async ({event}) => {
  let content = '', token = null;
  try { ({content, token} = await readText('/seen.md')); } catch {}
  await writeText('/seen.md', content + `${event.id}:${event.type}:${event.data}\\n`, {ifMatch: token});
};
"""

private func seen(_ space: Space) async throws -> [String]? {
  guard let (_, data) = try? await space.fs(.shared).read("/seen.md") else { return nil }
  return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

@Suite(.deterministicDependencies) struct StreamObserveTests {
  @Test func `a handler fires per event and every dial resumes after the last one taken`() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/record.js", Data(recording.utf8), ifMatch: nil)
      let events = EventServer()
      try await withEventServer(events) { url, sources in
        try await withHandlerFiring(space, sources: sources) { worker, _ in
          var world = ToolWorld(worker: worker, session: session)
          let armed = try await world.run("observe", .object(["url": .string(url.absoluteString), "handler": "/record.js"]))
          guard case let .observe(result) = armed else { Issue.record("unexpected \(armed)"); return }
          #expect(result.source == .stream(url))
          try await until("first dial") { events.dials.count == 1 }
          #expect(events.dials[0].lastEventID == nil)
          events.send("id: 1\ndata: a\n\nevent: build\ndata: b\n\n", on: 0)
          try await until("both events fired") { try await seen(space)?.count == 2 }
          #expect(try await seen(space) == ["1:message:a", "1:build:b"])
          events.send("id: 2\ndata: c\n\n", on: 0)
          events.dials[0].stream.finish()
          try await untilAdvancing("second dial", time) { events.dials.count == 2 }
          #expect(events.dials[1].lastEventID == "2")
        }
        try await withHandlerFiring(space, sources: sources) { _, _ in
          try await until("dial after a restart") { events.dials.count == 3 }
          #expect(events.dials[2].lastEventID == "2")
        }
      }
      #expect(try await seen(space) == ["1:message:a", "1:build:b", "2:message:c"])
      #expect(try await handlerNotifications(space, session).isEmpty)
    }
  }

  @Test func `a failed firing keeps its event and retries it on the same connection`() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/flaky.js", Data("""
      import {readText, writeText} from 'wuhu:space';
      export default async ({event}) => {
        if (event.data === 'flaky') {
          let first = true;
          try { await writeText('/flaked.md', 'x', {ifMatch: null}); } catch { first = false; }
          if (first) throw new Error('first try fails');
        }
        let content = '', token = null;
        try { ({content, token} = await readText('/seen.md')); } catch {}
        await writeText('/seen.md', content + event.data + '\\n', {ifMatch: token});
      };
      """.utf8), ifMatch: nil)
      let events = EventServer()
      try await withEventServer(events) { url, sources in
        try await withHandlerFiring(space, sources: sources) { worker, _ in
          var world = ToolWorld(worker: worker, session: session)
          _ = try await world.run("observe", .object(["url": .string(url.absoluteString), "handler": "/flaky.js"]))
          try await until("first dial") { events.dials.count == 1 }
          events.send("id: 1\ndata: steady\n\nid: 2\ndata: flaky\n\n", on: 0)
          try await untilAdvancing("the failed event fired again", time) { try await seen(space)?.count == 2 }
          #expect(events.dials.count == 1)
        }
      }
      #expect(try await seen(space) == ["steady", "flaky"])
      let failures = try await handlerNotifications(space, session).map(\.content.text)
      #expect(failures.count == 1 && failures[0].contains("first try fails"))
    }
  }

  @Test func `an archived owner's idle stream keeps its slot and its connection`() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/record.js", Data(recording.utf8), ifMatch: nil)
      let events = EventServer()
      try await withEventServer(events) { url, sources in
        try await withHandlerFiring(space, sources: sources) { worker, _ in
          var world = ToolWorld(worker: worker, session: session)
          _ = try await world.run("observe", .object(["url": .string(url.absoluteString), "handler": "/record.js"]))
          try await until("first dial") { events.dials.count == 1 }
          events.send("id: 1\ndata: a\n\n", on: 0)
          try await until("fired") {
            try await space.query("SELECT outcome FROM subscription_firings", as: space.principal(of: session)).rows == [[.text("ok")]]
          }
          _ = try await space.sessions.archive(session, grace: .seconds(100))
          try await holds("the archived owner's slot stays") { try await space.sessions.armedSubscriptions(session).count == 1 }
          try await space.sessions.unarchive(session)
          events.send("id: 2\ndata: b\n\n", on: 0)
          try await until("fired after unarchive") { try await seen(space)?.count == 2 }
        }
      }
      #expect(try await seen(space) == ["1:message:a", "2:message:b"])
    }
  }

  @Test func `an empty id resets where the stream resumes, across a restart`() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/record.js", Data(recording.utf8), ifMatch: nil)
      let events = EventServer()
      try await withEventServer(events) { url, sources in
        try await withHandlerFiring(space, sources: sources) { worker, _ in
          var world = ToolWorld(worker: worker, session: session)
          _ = try await world.run("observe", .object(["url": .string(url.absoluteString), "handler": "/record.js"]))
          try await until("first dial") { events.dials.count == 1 }
          events.send("id: 1\ndata: a\n\nid:\ndata: b\n\n", on: 0)
          try await until("both fired") { try await seen(space)?.count == 2 }
          events.dials[0].stream.finish()
          try await untilAdvancing("second dial", time) { events.dials.count == 2 }
        }
        try await withHandlerFiring(space, sources: sources) { _, _ in
          try await until("dial after a restart") { events.dials.count == 3 }
        }
      }
      #expect(try await seen(space) == ["1:message:a", "null:message:b"])
      #expect(events.dials.map(\.lastEventID) == [nil, nil, nil])
    }
  }

  @Test(arguments: [false, true]) func `a busy stream is dialled again only after its Retry-After`(asDate: Bool) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      @Dependency(\.date.now) var now
      let retryAfter = asDate ? Date.HTTPFormatStyle().format(now.addingTimeInterval(120)) : "120"
      let events = EventServer { $0 == 0 ? Response(status: .tooManyRequests, headers: [.retryAfter: retryAfter]) : nil }
      try await withEventServer(events) { url, sources in
        try await withHandlerFiring(space, sources: sources) { worker, _ in
          var world = ToolWorld(worker: worker, session: session)
          _ = try await world.run("observe", .object(["url": .string(url.absoluteString), "handler": "/record.js"]))
          try await until("first dial") { events.dials.count == 1 }
          await time.advance(by: 119)
          try await holds("no dial before Retry-After") { events.dials.count == 1 }
          try await untilAdvancing("second dial", time) { events.dials.count == 2 }
        }
      }
      #expect(try await handlerNotifications(space, session).isEmpty)
    }
  }

  @Test func `cancelling a stream observation closes its connection`() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let events = EventServer()
      try await withEventServer(events) { url, sources in
        try await withHandlerFiring(space, sources: sources) { worker, _ in
          var world = ToolWorld(worker: worker, session: session)
          let armed = try await world.run("observe", .object(["url": .string(url.absoluteString), "handler": "/record.js"]))
          guard case let .observe(result) = armed else { Issue.record("unexpected \(armed)"); return }
          try await until("first dial") { events.dials.count == 1 }
          _ = try await world.run("cancel", .object(["id": .string(result.subscriptionID.rawValue)]))
          try await until("the connection closes") { !events.send(": ping\n\n", on: 0) }
        }
      }
      #expect(events.dials.count == 1)
    }
  }

  @Test func `a group observer's handler fires per event as its group`() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/record.js", Data(recording.utf8), ifMatch: nil)
      let events = EventServer()
      let owners = Mutex<[SubscriptionOwner]>([])
      try await withEventServer(events) { url, sources in
        let signed = EventSources(token: { owner, _ in
          owners.withLock { $0.append(owner) }
          return try await sources.token(owner, url)
        }, fetch: sources.fetch)
        try await withHandlerFiring(space, sources: signed) { _, owner in
          let observe = SubscriptionObserveInput(sql: nil, url: url.absoluteString, throttleSeconds: nil)
          _ = try await owner.armObserver(.shared, ObserverInput(name: "feed", handler: "/record.js", observe: observe, timer: nil, sessionsPerHour: nil))
          try await until("first dial") { events.dials.count == 1 }
          events.send("id: 9\ndata: hello\n\n", on: 0)
          try await until("fired") {
            try await seen(space) == ["9:message:hello"]
          }
        }
      }
      #expect(owners.withLock { $0 } == [.group(.shared)])
    }
  }
}
