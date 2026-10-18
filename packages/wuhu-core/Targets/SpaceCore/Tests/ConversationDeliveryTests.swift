import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing

// A space whose clock the test advances, so window expiry and reminder backoff
// are observable without sleeping.
final class MovingInstant: Sendable {
  private let instant: Mutex<Date>

  init(_ start: Date) { instant = Mutex(start) }

  var now: Date { instant.withLock { $0 } }

  func advance(_ seconds: TimeInterval) {
    instant.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

final class MovingClockSpace: Sendable {
  let space: Space
  private let clock: MovingInstant

  init(start: Date = fixedDate) throws {
    let clock = MovingInstant(start)
    self.clock = clock
    space = try withDependencies {
      $0.date = DateGenerator { clock.now }
      $0.uuid = .incrementing
    } operation: {
      try Space.inMemory()
    }
  }

  var store: SessionStore { space.sessions }

  func advance(_ seconds: TimeInterval) { clock.advance(seconds) }
}

private let utc = TimeZone(identifier: "UTC")!

private func human(_ id: String) -> Sender { Sender(id: id, timeZone: utc) }

@Suite struct ConversationDeliveryTests {
  private func agent(_ store: SessionStore, _ title: String = "a") async throws -> SessionID {
    try await store.createSession(group: .shared, title: title, kind: .agent, createdBy: "morgan", model: .test)
  }

  @Test func `the box owner hears everything posted into its box`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store)
    let delivery = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "hi"),
    )
    #expect(delivery.enqueued == [owner])
    #expect(delivery.message.conversation == ConversationID(owner.rawValue))
  }

  private func task(_ store: SessionStore, parent: SessionID) async throws -> SessionID {
    try await store.createSession(
      group: .shared,
      title: "t", kind: .task, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test),
    )
  }

  @Test func `a person can neither post to a task nor DM it, and nothing is stored`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await agent(rig.store)
    let task = try await task(rig.store, parent: parent)
    await #expect(throws: SessionStoreError.taskTakesNoHumanInput(task.rawValue)) {
      _ = try await rig.store.post(
        .box(task), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "hi"),
      )
    }
    await #expect(throws: SessionStoreError.humanAgentDirectMessage) {
      _ = try await rig.store.post(
        .dm(with: task.rawValue), messageID: MessageID("m2"), sender: human("carol"), content: .init(text: "hi"),
      )
    }
    #expect(try await rig.store.message(MessageID("m2")) == nil)
    #expect(try await rig.store.conversations(member: "carol").isEmpty)
  }

  @Test func `a session reaches a task in its DM, never its box`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await agent(rig.store)
    let task = try await task(rig.store, parent: parent)
    let delivery = try await rig.store.post(
      .dm(with: task.rawValue), messageID: MessageID("m1"), sender: human(parent.rawValue),
      senderSession: parent, content: .init(text: "one more thing"),
    )
    #expect(delivery.enqueued == [task])
    await #expect(throws: SessionStoreError.taskHasNoBox(task.rawValue)) {
      _ = try await rig.store.post(
        .box(task), messageID: MessageID("m2"), sender: human(parent.rawValue),
        senderSession: parent, content: .init(text: "mine"),
      )
    }
  }

  @Test func `a person's post that would reach only tasks is refused`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await agent(rig.store)
    let task = try await task(rig.store, parent: parent)
    let group = try await rig.store.createConversation(members: ["carol"], in: .shared)
    _ = try await rig.store.post(
      .conversation(group), messageID: MessageID("t1"), sender: human(task.rawValue),
      senderSession: task, content: .init(text: "done"),
    )
    await #expect(throws: SessionStoreError.taskTakesNoHumanInput(task.rawValue)) {
      _ = try await rig.store.post(
        .conversation(group), messageID: MessageID("m1"), sender: human("carol"),
        replyTarget: MessageID("t1"), content: .init(text: "about that"),
      )
    }
    #expect(try await rig.store.message(MessageID("m1")) == nil)
  }

  @Test func `a reply target forwards to whoever posted it`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store, "owner")
    let other = try await agent(rig.store, "other")
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human(other.rawValue),
      senderSession: other, content: .init(text: "a note"),
    )
    rig.advance(10000)
    let delivery = try await rig.store.post(
      .box(owner), messageID: MessageID("m2"), sender: human("carol"),
      replyTarget: MessageID("m1"), content: .init(text: "about that"),
    )
    #expect(Set(delivery.enqueued) == [owner, other])
  }

  private func visited(_ rig: MovingClockSpace) async throws -> (owner: SessionID, visitor: SessionID) {
    let owner = try await agent(rig.store, "owner")
    let visitor = try await agent(rig.store, "visitor")
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("v1"), sender: human(visitor.rawValue),
      senderSession: visitor, content: .init(text: "dropping in"),
    )
    return (owner, visitor)
  }

  private func carol(_ rig: MovingClockSpace, _ owner: SessionID, _ id: String) async throws -> Set<SessionID> {
    try await Set(rig.store.post(.box(owner), messageID: MessageID(id), sender: human("carol"), content: .init(text: id)).enqueued)
  }

  @Test func `the attention window forwards while both bounds hold`() async throws {
    let rig = try MovingClockSpace()
    let (owner, visitor) = try await visited(rig)
    for index in 1 ... ConversationDefaults.windowMessages {
      rig.advance(Double(ConversationDefaults.windowSeconds - 1) / Double(ConversationDefaults.windowMessages))
      #expect(try await carol(rig, owner, "m\(index)") == [owner, visitor])
    }
  }

  @Test func `the attention window closes after its message bound, inside its time bound`() async throws {
    let rig = try MovingClockSpace()
    let (owner, visitor) = try await visited(rig)
    for index in 1 ... ConversationDefaults.windowMessages {
      #expect(try await carol(rig, owner, "m\(index)") == [owner, visitor])
    }
    #expect(try await carol(rig, owner, "over") == [owner])
  }

  @Test func `the attention window closes after its time bound, inside its message bound`() async throws {
    let rig = try MovingClockSpace()
    let (owner, visitor) = try await visited(rig)
    #expect(try await carol(rig, owner, "m1") == [owner, visitor])
    rig.advance(Double(ConversationDefaults.windowSeconds + 1))
    #expect(try await carol(rig, owner, "late") == [owner])
  }

  @Test(arguments: [false, true]) func attentionDeliveryOrder(reversePosts: Bool) async throws {
    let rig = try MovingClockSpace()
    let a = try await agent(rig.store)
    let b = try await agent(rig.store)
    let sessions = [a, b].sorted { $0.rawValue < $1.rawValue }
    let channel = try await rig.store.createConversation(members: ["carol"], in: .shared)
    for session in reversePosts ? sessions.reversed().map({ $0 }) : sessions {
      _ = try await rig.store.post(
        .conversation(channel), messageID: MessageID(session.rawValue), sender: human(session.rawValue),
        senderSession: session, content: .init(text: "here"),
      )
    }
    let delivery = try await rig.store.post(
      .conversation(channel), messageID: MessageID("human"), sender: human("carol"), content: .init(text: "hello"),
    )
    #expect(delivery.enqueued == sessions)
  }

  @Test func `attention uses the latest post timestamp after the clock moves backward`() async throws {
    let rig = try MovingClockSpace()
    let (owner, visitor) = try await visited(rig)
    rig.advance(-1000)
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("rewound"), sender: human(visitor.rawValue),
      senderSession: visitor, content: .init(text: "again"),
    )
    rig.advance(1001)
    #expect(try await carol(rig, owner, "later") == [owner])
  }

  @Test func `a DM is created once and both posts land in the same conversation`() async throws {
    let rig = try MovingClockSpace()
    let a = try await agent(rig.store, "a")
    let b = try await agent(rig.store, "b")
    let first = try await rig.store.post(
      .dm(with: b.rawValue), messageID: MessageID("m1"), sender: human(a.rawValue),
      senderSession: a, content: .init(text: "hi"),
    )
    let second = try await rig.store.post(
      .dm(with: a.rawValue), messageID: MessageID("m2"), sender: human(b.rawValue),
      senderSession: b, content: .init(text: "hey"),
    )
    #expect(first.message.conversation == second.message.conversation)
    #expect(first.enqueued == [b])
    #expect(second.enqueued == [a])
    let record = try await rig.store.conversation(first.message.conversation)
    #expect(record.kind == .dmSession)
    #expect(record.members.count == 2)
  }

  @Test func `posting the same message id twice replays instead of duplicating`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store)
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "hi"),
    )
    let replay = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "hi"),
    )
    #expect(replay.replayed)
    #expect(replay.enqueued.isEmpty)
    #expect(try await rig.store.messages(conversation: .init(owner.rawValue)).count == 1)
  }

  @Test func `a reply target in another conversation is refused`() async throws {
    let rig = try MovingClockSpace()
    let a = try await agent(rig.store, "a")
    let b = try await agent(rig.store, "b")
    _ = try await rig.store.post(
      .box(a), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "hi"),
    )
    await #expect(throws: SessionStoreError.replyTargetInAnotherConversation("m1")) {
      _ = try await rig.store.post(
        .box(b), messageID: MessageID("m2"), sender: human("carol"),
        replyTarget: MessageID("m1"), content: .init(text: "about that"),
      )
    }
  }

  @Test func `a human member who did not send gets a notification row`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store)
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "hi"),
    )
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("m2"), sender: human(owner.rawValue),
      senderSession: owner, content: .init(text: "answered"),
    )
    let rows = try await rig.store.notifications(recipient: "carol")
    #expect(rows.map(\.kind) == [.conversationMessage])
    #expect(rows[0].payload.contains("answered"))
  }
}
