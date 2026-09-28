import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct WorkSignalTests {
  @Test func everyQueueWriterPostsAWorkSignal() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      var signals = store.workSignals().makeAsyncIterator()

      _ = try await store.enqueue(sid, input: SessionFix.message("verb"))
      #expect(await signals.next() == sid)

      _ = try await store.fireSubscription(
        sid,
        subscriptionID: SubscriptionID("sub-1"),
        notification: .init(
          id: UUID(), timestamp: fixedDate, kind: .timer,
          subscriptionID: .init("sub-1"), content: .init(text: "tick"),
        ),
        advance: .retire,
      )
      #expect(await signals.next() == sid)

      _ = try await store.post(
        .box(sid),
        messageID: MessageID("m1"),
        sender: SessionFix.sender,
        content: .init(text: "fan-out"),
      )
      #expect(await signals.next() == sid)
    }
  }

  @Test func signalsCoalescePerSessionUntilConsumed() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let first = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
      let second = try await store.createSession(group: .shared, title: "b", kind: .agent, createdBy: "morgan", model: .test)
      var signals = store.workSignals().makeAsyncIterator()

      _ = try await store.enqueue(first, input: SessionFix.message("one"))
      _ = try await store.enqueue(first, input: SessionFix.message("two"))
      _ = try await store.enqueue(second, input: SessionFix.message("three"))

      #expect(await signals.next() == first, "two unconsumed signals collapse into one")
      #expect(await signals.next() == second)

      _ = try await store.enqueue(first, input: SessionFix.message("four"))
      #expect(await signals.next() == first, "a consumed signal re-arms")
    }
  }
}
