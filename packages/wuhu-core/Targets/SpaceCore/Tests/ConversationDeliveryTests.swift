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
    await #expect(throws: SessionStoreError.taskTakesNoHumanInput(task.rawValue)) {
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

  @Test func `a person's mention of a task reaches everyone else and skips the task`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store)
    let task = try await task(rig.store, parent: owner)
    let delivery = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"),
      content: .init(text: "@\(task.rawValue) status?"),
    )
    #expect(delivery.enqueued == [owner])

    let group = try await rig.store.createConversation(members: ["carol", "dave", task.rawValue], in: .shared)
    let grouped = try await rig.store.post(
      .conversation(group), messageID: MessageID("m2"), sender: human("carol"),
      content: .init(text: "@\(task.rawValue) status?"),
    )
    #expect(grouped.enqueued.isEmpty)
    #expect(try await rig.store.notifications(recipient: "dave").count == 1)
  }

  @Test func `a person's post that would reach only tasks is refused`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await agent(rig.store)
    let task = try await task(rig.store, parent: parent)
    let group = try await rig.store.createConversation(members: ["carol", task.rawValue], in: .shared)
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

  @Test func `a mention forwards to the named session`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store, "owner")
    let mentioned = try await agent(rig.store, "mentioned")
    let delivery = try await rig.store.post(
      .box(owner),
      messageID: MessageID("m1"),
      sender: human("carol"),
      content: .init(text: "hey @\(mentioned.rawValue) look at this"),
    )
    #expect(Set(delivery.enqueued) == [owner, mentioned])
  }

  @Test func `an at-sign that is not a session id forwards to nobody`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store)
    let delivery = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"),
      content: .init(text: "mail me at a@b-c-d.example"),
    )
    #expect(delivery.enqueued == [owner])
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

  @Test func `the attention window forwards while either bound holds and closes when both lapse`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store, "owner")
    let visitor = try await agent(rig.store, "visitor")
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("v1"), sender: human(visitor.rawValue),
      senderSession: visitor, content: .init(text: "dropping in"),
    )

    let inWindow = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "one"),
    )
    #expect(Set(inWindow.enqueued) == [owner, visitor])

    // Past the time bound but still inside the message bound.
    rig.advance(1000)
    let byCount = try await rig.store.post(
      .box(owner), messageID: MessageID("m2"), sender: human("carol"), content: .init(text: "two"),
    )
    #expect(Set(byCount.enqueued) == [owner, visitor])

    // Past both bounds: the window is closed.
    for index in 3 ... 13 {
      _ = try await rig.store.post(
        .box(owner), messageID: MessageID("m\(index)"), sender: human("carol"),
        content: .init(text: "filler"),
      )
    }
    let expired = try await rig.store.post(
      .box(owner), messageID: MessageID("last"), sender: human("carol"), content: .init(text: "late"),
    )
    #expect(expired.enqueued == [owner])
  }

  @Test func `a task posting in a box never enters the attention window`() async throws {
    let rig = try MovingClockSpace()
    let owner = try await agent(rig.store, "owner")
    let task = try await rig.store.createSession(
      group: .shared,
      title: "t", kind: .task, parent: owner, createdBy: owner.rawValue, executor: .kernel(.test),
    )
    _ = try await rig.store.post(
      .box(owner), messageID: MessageID("t1"), sender: human(task.rawValue),
      senderSession: task, content: .init(text: "on it"),
    )
    let delivery = try await rig.store.post(
      .box(owner), messageID: MessageID("m1"), sender: human("carol"), content: .init(text: "status?"),
    )
    #expect(delivery.enqueued == [owner])
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
