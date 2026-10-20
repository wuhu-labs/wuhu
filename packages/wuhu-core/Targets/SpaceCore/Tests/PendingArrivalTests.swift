import DeterministicDependencies
import Foundation
import SessionDomain
import SpaceCore
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct PendingArrivalTests {
  private let utc = TimeZone(identifier: "UTC")!

  @Test func `each urgency keeps its earliest arrival: a person's post into the box is direct, a session's DM other`() async throws {
    let rig = try MovingClockSpace()
    let store = rig.store
    let owner = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "morgan", model: .test)
    let peer = try await store.createSession(group: .shared, title: "b", kind: .agent, createdBy: "morgan", model: .test)
    var pending = store.observePendingArrivals(owner).makeAsyncIterator()
    #expect(try await pending.next() == [])

    _ = try await store.post(
      .dm(with: owner.rawValue), messageID: MessageID("m1"), sender: Sender(id: peer.rawValue, timeZone: utc),
      senderSession: peer, content: .init(text: "fyi"),
    )
    let other = PendingArrival(urgency: .other, arrivedAt: fixedDate)
    #expect(try await pending.next() == [other])

    rig.advance(85)
    _ = try await store.post(.box(owner), messageID: MessageID("m2"), sender: Sender(id: "carol", timeZone: utc), content: .init(text: "hi"))
    let direct = PendingArrival(urgency: .direct, arrivedAt: fixedDate.addingTimeInterval(85))
    #expect(try await pending.next() == [direct, other])

    rig.advance(5)
    _ = try await store.post(.box(owner), messageID: MessageID("m3"), sender: Sender(id: "carol", timeZone: utc), content: .init(text: "still there?"))
    _ = try await store.drainQueue(owner)
    #expect(try await pending.next() == [])

    var peers = store.observePendingArrivals(peer).makeAsyncIterator()
    #expect(try await peers.next() == [])
  }
}
