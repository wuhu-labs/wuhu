import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

struct SessionNotificationTests {
  @Test func settlingNotifiesNobody() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message("do it"))
      _ = try await store.drainQueue(sid)
      _ = try await store.appendAssistant(
        sid, attemptID: UUID(), message: SessionFix.assistant("all done"), metadata: SessionFix.metadata,
      )
      #expect(try await store.record(sid).work == .noWork)
      #expect(try await store.notifications(recipient: "morgan").isEmpty)
      #expect(try await store.notifications(recipient: "owner").isEmpty)
    }
  }

  @Test func aKernelResumeQueuesNoReminder() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(
        sid, input: SessionFix.message("please review", conversation: sid.rawValue, owesReply: true),
      )
      _ = try await store.drainQueue(sid)
      try await store.markInterrupted(sid)
      _ = try await store.appendAssistant(
        sid, attemptID: UUID(), message: SessionFix.assistant("finished anyway"), metadata: SessionFix.metadata,
      )
      try await store.markResumed(sid)

      #expect(try await store.notifications(recipient: "morgan").isEmpty)
      let hydration = try await store.hydrate(sid)
      #expect(hydration.undrained.isEmpty, "the resumed loop reads the owe from its transcript")
      #expect(hydration.record.work == .noWork)
    }
  }

  @Test func erroredNotifiesTheOwner() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.enqueue(sid, input: SessionFix.message("do it"))
      _ = try await store.drainQueue(sid)
      try await store.markErrored(sid, message: "provider exploded")

      let rows = try await store.notifications(recipient: "owner")
      #expect(rows.map(\.kind) == [.sessionErrored])
      #expect(rows[0].payload.contains("provider exploded"))
      #expect(try await store.notifications(recipient: "morgan").isEmpty)
    }
  }

  @Test func watermarkAdvancesWholesaleAndBadgesDerive() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let owner = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
      let sender = Sender(id: owner.rawValue, timeZone: TimeZone(identifier: "UTC")!)

      _ = try await store.post(
        .box(owner), messageID: MessageID("m1"),
        sender: Sender(id: "carol", timeZone: TimeZone(identifier: "UTC")!), content: .init(text: "q1"),
      )
      _ = try await store.post(
        .box(owner), messageID: MessageID("m2"),
        sender: sender, senderSession: owner, replyTarget: MessageID("m1"), content: .init(text: "a1"),
      )
      _ = try await store.post(
        .box(owner), messageID: MessageID("m3"),
        sender: sender, senderSession: owner, replyTarget: MessageID("m1"), content: .init(text: "a2"),
      )
      let threadSource = owner.rawValue
      #expect(try await store.unreadCount(identity: "carol", source: threadSource) == 2)

      try await store.advanceWatermark(identity: "carol", source: threadSource)
      #expect(try await store.unreadCount(identity: "carol", source: threadSource) == 0)

      _ = try await store.post(
        .box(owner), messageID: MessageID("m4"),
        sender: sender, senderSession: owner, replyTarget: MessageID("m1"), content: .init(text: "a3"),
      )
      #expect(try await store.unreadCount(identity: "carol", source: threadSource) == 1)
      #expect(try await store.unreadCount(identity: "dave", source: threadSource) == 0)
    }
  }
}
