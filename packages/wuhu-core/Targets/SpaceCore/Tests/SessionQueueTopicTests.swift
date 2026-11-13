import DeterministicDependencies
import Foundation
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct SessionQueueTopicTests {
  private let utc = TimeZone(identifier: "UTC")!

  private func notice(_ text: String) -> QueueInput {
    .notification(SystemNotification(id: UUID(), timestamp: fixedDate, kind: .timer, subscriptionID: SubscriptionID("s"), content: .init(text: text)))
  }

  private func texts(_ store: SessionStore, _ id: SessionID) async throws -> [String] {
    try await store.undrainedInputs(id).map { entry in
      if case let .notification(notification) = entry.input { notification.content.text } else { "" }
    }
  }

  @Test func `a delayed input waits until it is due and holds back no later input`() async throws {
    let rig = try MovingClockSpace()
    let store = rig.store
    let id = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
    try await store.markInterrupted(id)
    try await store.put(id, input: notice("later"), due: fixedDate.addingTimeInterval(60))
    try await store.put(id, input: notice("now"))
    #expect(try await texts(store, id) == ["now"])
    #expect(try await store.drainQueue(id).items.count == 1)

    rig.advance(60)
    #expect(try await texts(store, id) == ["later"])
    #expect(try await store.drainQueue(id).items.count == 1)
    #expect(try await texts(store, id) == [])
  }

  @Test func `an input on a topic replaces the unseen one, and clearing the topic takes it back`() async throws {
    let rig = try MovingClockSpace()
    let store = rig.store
    let id = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
    try await store.markInterrupted(id)
    try await store.put(id, input: notice("first"), topic: "quiet")
    try await store.put(id, input: notice("other"))
    try await store.put(id, input: notice("second"), topic: "quiet")
    #expect(try await texts(store, id) == ["other", "second"])
    try await store.clear(id, topic: "quiet")
    try await store.deliverMail()
    #expect(try await texts(store, id) == ["other"])

    _ = try await store.drainQueue(id)
    try await store.put(id, input: notice("third"), topic: "quiet")
    try await store.clear(id, topic: "quiet")
    try await store.deliverMail()
    #expect(try await texts(store, id) == [])
  }

  @Test func `the yield deadline is the earliest grace of the due input, from when it came due`() async throws {
    let rig = try MovingClockSpace()
    try await rig.space.registerPerson("carol")
    let store = rig.store
    let owner = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
    try await store.markInterrupted(owner)
    let peer = try await store.createSession(group: .shared, title: "b", kind: .agent, createdBy: "morgan", model: .test)
    func deadline() async throws -> Date? {
      try await store.deliverMail()
      return try await rig.space.worker.call(SessionCell.ID(owner.rawValue)) { try $0.rows.yieldDeadline(owner) }
    }
    #expect(try await deadline() == nil)

    _ = try await store.post(
      .dm(with: owner.rawValue), messageID: MessageID("m1"), sender: Sender(id: peer.rawValue, timeZone: utc),
      senderSession: peer, content: .init(text: "fyi"),
    )
    #expect(try await deadline() == fixedDate.addingTimeInterval(90))

    try await store.put(owner, input: notice("later"), due: fixedDate.addingTimeInterval(30))
    rig.advance(70)
    _ = try await store.post(.box(owner), messageID: MessageID("m2"), sender: Sender(id: "carol", timeZone: utc), content: .init(text: "hi"))
    #expect(try await deadline() == fixedDate.addingTimeInterval(80))

    _ = try await store.drainQueue(owner)
    #expect(try await deadline() == nil)
  }
}
