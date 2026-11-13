import Dependencies
import DeterministicDependencies
import Foundation
import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies)
struct SessionNotificationTests {
  @Test func aKernelResumeQueuesNoReminder() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(
        sid, input: SessionFix.message("please review", conversation: sid.rawValue, owesReply: true),
      )
      _ = try await store.drainQueue(sid)
      try await store.markInterrupted(sid)
      try await store.markResumed(sid)

      #expect(try await store.inbox("morgan").isEmpty)
      let hydration = try await store.hydrate(sid)
      #expect(hydration.queueHead == hydration.queueTail, "resume adds no queue input")
    }
  }

  @Test func erroredDoesNotInventAnOwnerInbox() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await store.put(sid, input: SessionFix.message("do it"))
      _ = try await store.drainQueue(sid)
      try await store.markErrored(sid, message: "provider exploded")
      try await store.deliverMail()

      let rows = try await store.inbox("owner")
      #expect(rows.isEmpty)
      #expect(try await store.inbox("morgan").isEmpty)
    }
  }

  @Test func watermarkAdvancesWholesaleAndBadgesDerive() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      try await space.registerPerson("carol")
      let store = space.sessions
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
