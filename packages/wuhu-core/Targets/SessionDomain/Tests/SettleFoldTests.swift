import Foundation
import SessionDomain
import Testing

@Suite struct SettleFoldTests {
  private let later = Fix.instant.addingTimeInterval(60)
  private let muchLater = Fix.instant.addingTimeInterval(3600)

  @Test func `a scoped delivery owes a reply and an own post clears it`() {
    #expect(SettleState(folding: [Fix.delivered()]).owedConversations == [ConversationID("ch1")])
    #expect(SettleState(folding: [Fix.delivered(), Fix.posted(at: later)]).owedConversations.isEmpty)
  }

  @Test func `an out-of-scope delivery owes nothing`() {
    let folded = SettleState(folding: [Fix.delivered(conversation: "grp", owesReply: false)])
    #expect(folded.owedConversations.isEmpty)
  }

  @Test func `a delivery landing after the post still reads owed`() {
    let folded = SettleState(folding: [
      Fix.delivered(at: Fix.instant),
      Fix.posted(at: later),
      Fix.delivered(at: muchLater),
    ])
    #expect(folded.owedConversations == [ConversationID("ch1")])
  }

  @Test func `a reminder fires once and never again until a new delivery`() {
    let reminded = SettleState(folding: [
      Fix.delivered(),
      .owedReminder(conversations: [ConversationID("ch1")], at: later),
    ])
    #expect(reminded.owedConversations.isEmpty)
    #expect(reminded.owed[ConversationID("ch1")] == .reminded)

    let redelivered = SettleState(folding: [
      Fix.delivered(),
      .owedReminder(conversations: [ConversationID("ch1")], at: later),
      Fix.delivered(at: muchLater),
    ])
    #expect(redelivered.owedConversations == [ConversationID("ch1")])
  }

  @Test func `a request opens and only its final closes it`() {
    let open = SettleState(folding: [Fix.delivered(kind: .request, request: "r1", owesReply: false)])
    #expect(open.openRequests[RequestID("r1")]?.conversation == ConversationID("ch1"))

    let progressed = SettleState(folding: [
      Fix.delivered(kind: .request, request: "r1", owesReply: false),
      Fix.posted(kind: .progress, request: "r1", at: later),
    ])
    #expect(progressed.openRequests[RequestID("r1")] != nil)

    let closed = SettleState(folding: [
      Fix.delivered(kind: .request, request: "r1", owesReply: false),
      Fix.posted(kind: .final, request: "r1", at: later),
    ])
    #expect(closed.openRequests.isEmpty)
  }

  @Test func `park reminders accumulate on the open request`() {
    let folded = SettleState(folding: [
      Fix.delivered(kind: .request, request: "r1", owesReply: false),
      .parkReminder(request: RequestID("r1"), at: later),
      .parkReminder(request: RequestID("r1"), at: muchLater),
    ])
    let open = folded.openRequests[RequestID("r1")]
    #expect(open?.parkReminderCount == 2)
    #expect(open?.lastParkReminderAt == muchLater)
  }

  @Test func `backoff is 1, 5, 15 minutes and then flat`() {
    #expect(ParkBackoff.delay(after: 0) == .zero)
    #expect(ParkBackoff.delay(after: 1) == .seconds(60))
    #expect(ParkBackoff.delay(after: 2) == .seconds(300))
    #expect(ParkBackoff.delay(after: 3) == .seconds(900))
    #expect(ParkBackoff.delay(after: 9) == .seconds(900))
  }

  @Test func `the first park reminder is due immediately and the deadline ends the series`() {
    let fresh = OpenRequest(id: .init("r1"), conversation: .init("ch1"), openedAt: Fix.instant)
    #expect(ParkBackoff.nextFire(after: fresh, now: Fix.instant) == Fix.instant)

    var second = fresh
    second.parkReminderCount = 1
    second.lastParkReminderAt = Fix.instant
    #expect(ParkBackoff.nextFire(after: second, now: Fix.instant) == Fix.instant.addingTimeInterval(60))

    var bounded = second
    bounded.deadline = Fix.instant.addingTimeInterval(30)
    #expect(ParkBackoff.nextFire(after: bounded, now: Fix.instant) == nil)
  }

  @Test func `a queue input projects to the event the fold reads`() {
    let delivery = QueueInput.message(.init(
      id: UUID(),
      messageID: .init("m1"),
      conversationID: .init("ch1"),
      sender: .init(id: "alice", timeZone: Fix.utc),
      timestamp: Fix.instant,
      owesReply: true,
      content: .init(text: "hi"),
    ))
    guard case let .delivered(event)? = delivery.settleEvent else {
      Issue.record("a conversation message projects to a delivery")
      return
    }
    #expect(event.conversation == ConversationID("ch1"))
    #expect(event.owesReply)
  }
}
