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
