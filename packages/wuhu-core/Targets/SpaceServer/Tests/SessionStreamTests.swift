import Clocks
import Fetch
import FetchSSE
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

private func itemKind(_ event: SessionStreamEvent) -> String? {
  guard case let .item(_, _, item) = event, case let .object(fields) = item else { return nil }
  return fields.keys.first
}

@Suite struct SessionStreamTests {
  @Test func channelObserveEmitsAHeartbeatEachSecond() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let clock = TestClock<Duration>()
      let response = conversationStreamResponse(space: harness.space, store: harness.store, conversation: ConversationID(id.rawValue), after: 0, viewer: .shared, clock: clock)
      let received = Mutex<[String]>([])
      let reader = Task {
        for try await chunk in response.body.asyncBytes() {
          received.withLock { $0.append(String(decoding: chunk, as: UTF8.self)) }
          if received.withLock({ $0.count }) == 3 { break }
        }
      }
      defer { reader.cancel() }

      // The preamble is on the wire before any clock advance.
      for _ in 0 ..< 100 where received.withLock({ $0.count }) < 1 { await Task.yield() }
      #expect(received.withLock { $0 } == [":\n\n"])

      await clock.advance(by: .milliseconds(999))
      for _ in 0 ..< 20 { await Task.yield() }
      #expect(received.withLock { $0 } == [":\n\n"])

      await clock.advance(by: .milliseconds(1))
      for _ in 0 ..< 100 where received.withLock({ $0.count }) < 2 { await Task.yield() }
      #expect(received.withLock { $0 } == [":\n\n", ":\n\n"])

      await clock.advance(by: .seconds(1))
      for _ in 0 ..< 100 where received.withLock({ $0.count }) < 3 { await Task.yield() }
      #expect(received.withLock { $0 } == [":\n\n", ":\n\n", ":\n\n"])
    }
  }

  @Test func materializedFiresStrictlyAfterTheDurableCommit() async throws {
    try await withSessionDeps {
      let gate = Gate()
      let harness = try await SessionHarness { request, hub in
        hub.publish(session: request.sessionID, .started(attemptID: request.attemptID))
        hub.publish(session: request.sessionID, .delta(
          attemptID: request.attemptID,
          event: .textDelta(contentIndex: 0, delta: "Hello", partial: AssistantMessage(content: [.text(.init(text: "Hello"))])),
        ))
        await gate.wait()
        return reply("Hello world")
      }
      let id = try await harness.createSession()
      let key = id.rawValue

      let response = try await harness.get("/v1/session/\(key)/direct")
      #expect(response.status == .ok)
      #expect(response.headers[.contentType]?.hasPrefix("text/event-stream") == true)

      // Consume the subscription's reset frame before enqueueing: an attempt
      // started event may legally overtake a reset still being read.
      var frames = response.sse().makeAsyncIterator()
      var events: [SessionStreamEvent] = [try streamEvent(try #require(await frames.next()).data)]

      try await harness.deliver("hi", to: id)

      // The materialization pass may race the enqueue into a separate first
      // attempt, so every check is per attempt: a delta must precede its own
      // attempt's materialized, never anyone else's.
      var deltas: [String: String] = [:]
      while let frame = try await frames.next() {
        let event = try streamEvent(frame.data)
        events.append(event)
        if case let .delta(attemptId, text) = event {
          deltas[attemptId, default: ""] += text
          let sawOwnMaterialized = events.contains {
            if case .materialized(attemptId, _) = $0 { true } else { false }
          }
          #expect(!sawOwnMaterialized)
          gate.open()
        }
        if itemKind(event) == "assistant" { break }
      }

      #expect(events.first == .reset(generation: 0))
      let firstMaterialized = events.firstIndex { $0.isMaterialized }
      let materializedIndex = try #require(firstMaterialized)
      guard case let .materialized(attemptId, entryId) = events[materializedIndex] else { return }
      #expect(attemptId == entryId)
      #expect(deltas[attemptId] == "Hello")
      // materialized precedes its committed entry event; a concurrent
      // attempt's hub frames may interleave, other items may not.
      let following = events[(materializedIndex + 1)...].first { if case .item = $0 { true } else { false } }
      guard case let .item(_, _, item) = try #require(following), case let .object(fields) = item else {
        Issue.record("expected the assistant item to follow materialized")
        return
      }
      #expect(fields.keys.first == "assistant")
      let started = events.contains {
        if case .started(attemptId) = $0 { true } else { false }
      }
      #expect(started, "the committed attempt was announced before it materialized")
    }
  }

  @Test func lateJoinersGetStartedPlusTheAccumulatedDelta() async throws {
    try await withSessionDeps {
      let gate = Gate()
      let harness = try await SessionHarness { request, hub in
        hub.publish(session: request.sessionID, .started(attemptID: request.attemptID))
        hub.publish(session: request.sessionID, .delta(
          attemptID: request.attemptID,
          event: .textDelta(contentIndex: 0, delta: "partial answer", partial: AssistantMessage(content: [.text(.init(text: "partial answer"))])),
        ))
        await gate.wait()
        return reply("partial answer, completed")
      }
      let id = try await harness.createSession()
      let key = id.rawValue

      try await harness.deliver("hi", to: id)
      try await until("attempt in flight") {
        !harness.runtime.attempts.inFlight(session: id).isEmpty
      }

      let response = try await harness.get("/v1/session/\(key)/direct")
      var started = false
      var accumulated = ""
      for try await frame in response.sse() {
        switch try streamEvent(frame.data) {
        case .started:
          started = true
        case let .delta(_, text):
          accumulated += text
        default:
          break
        }
        if started, accumulated == "partial answer" { break }
      }
      #expect(started)
      #expect(accumulated == "partial answer")
      gate.open()
    }
  }

  @Test func directCursorResumesWithoutGapsOrDuplicates() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("ack") }
      let id = try await harness.createSession()
      let key = id.rawValue

      try await harness.deliver("one", to: id)

      // The invariants are gapless coverage from 0 and a cursor resume with no
      // gap and no duplicate.
      var cursor: (Int, Int)?
      var firstPass: [Int] = []
      var sawMessage = false
      let first = try await harness.get("/v1/session/\(key)/direct")
      for try await frame in first.sse() {
        let event = try streamEvent(frame.data)
        if case let .item(generation, position, _) = event {
          firstPass.append(position)
          cursor = (generation, position)
        }
        if itemKind(event) == "message" { sawMessage = true }
        if sawMessage, itemKind(event) == "assistant" { break }
      }
      #expect(firstPass == Array(0 ..< firstPass.count))
      let (generation, position) = try #require(cursor)

      try await harness.deliver("two", to: id)

      let resumed = try await harness.get(
        "/v1/session/\(key)/direct",
        query: ["generation": String(generation), "position": String(position)],
      )
      var resumedEvents: [SessionStreamEvent] = []
      var resumedPositions: [Int] = []
      var assistantCount = 0
      for try await frame in resumed.sse() {
        let event = try streamEvent(frame.data)
        resumedEvents.append(event)
        if case let .item(_, position, _) = event {
          resumedPositions.append(position)
        }
        if itemKind(event) == "assistant" { assistantCount += 1 }
        if assistantCount == 1, resumedPositions.count == 2 { break }
      }
      // Same generation: no reset, and only the items past the cursor arrive.
      #expect(!resumedEvents.contains { if case .reset = $0 { true } else { false } })
      #expect(resumedPositions == [position + 1, position + 2])
    }
  }

  @Test func channelObserveResumesByCursorWithoutGapsOrDuplicates() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let key = id.rawValue

      let first = try await harness.call(
        "/v1/conversation/message", .object(["message": "m1", "session": .string(key)]), as: ConversationPostOutput.self,
      )
      _ = try await harness.call(
        "/v1/conversation/message", .object(["message": "m2", "session": .string(key)]), as: ConversationPostOutput.self,
      )
      _ = try await harness.call(
        "/v1/conversation/message", .object(["message": "m3", "session": .string(key)]), as: ConversationPostOutput.self,
      )

      let all = try JSONValueDecoder().decode(
        ConversationReadOutput.self,
        from: try await json(try await harness.get("/v1/conversation/\(key)/messages")),
      )
      #expect(all.messages.map(\.messageId).contains(first.messageId))
      let firstN = all.messages[0].n

      let response = try await harness.get("/v1/conversation/\(key)/observe", query: ["after": String(firstN)])
      #expect(response.status == .ok)
      var texts: [String] = []
      for try await frame in response.sse() {
        let entry = try JSONValueDecoder().decode(ConversationMessagePayload.self, from: #require(JSONValue.parse(frame.data)))
        texts.append(entry.text)
        if texts.count == 2 {
          _ = try await harness.call(
            "/v1/conversation/message", .object(["message": "m4", "session": .string(key)]), as: ConversationPostOutput.self,
          )
        }
        if texts.count == 3 { break }
      }
      #expect(texts == ["m2", "m3", "m4"])
    }
  }

  @Test func observingAColdSessionNeverMaterializesIt() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let key = id.rawValue

      let response = try await harness.get("/v1/session/\(key)/direct")
      for try await frame in response.sse() {
        #expect(try streamEvent(frame.data) == .reset(generation: 0))
        break
      }
      // The session actor was never woken: the store still reports the inert row
      // and the attempt topic is silent.
      let record = try await harness.store.record(id)
      #expect(record.work == .noWork)
      #expect(harness.runtime.attempts.inFlight(session: id).isEmpty)

      let missing = try await harness.get("/v1/session/\(UUID().uuidString.lowercased())/direct")
      #expect(missing.status == .notFound)
    }
  }
}

@Suite struct BoundedSessionStreamTests {
  @Test func staleGenerationResetsAndEndsRatherThanReplaying() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      _ = try await harness.store.restart(id)
      _ = try await harness.store.drainQueue(id)
      let response = try await harness.get("/v1/session/\(id.rawValue)/direct", query: ["paged": "true", "generation": "0", "position": "-1"])
      var events: [SessionStreamEvent] = []
      for try await frame in response.sse() { events.append(try streamEvent(frame.data)) }
      #expect(events == [.reset(generation: 1)])
    }
  }

  @Test func longForwardLagResetsAndEndsWithoutAnUnboundedReplay() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      for index in 0 ..< 205 { _ = try await harness.store.enqueue(id, input: .message(ConversationMessage(id: UUID(), messageID: MessageID("m\(index)"), conversationID: ConversationID(id.rawValue), sender: Sender(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: MessageContent(text: "entry \(index)")))) }
      _ = try await harness.store.drainQueue(id)
      let response = try await harness.get("/v1/session/\(id.rawValue)/direct", query: ["paged": "true", "generation": "0", "position": "-1"])
      var events: [SessionStreamEvent] = []
      for try await frame in response.sse() { events.append(try streamEvent(frame.data)) }
      #expect(events == [.reset(generation: 0)])
    }
  }
}
