import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct RequestReportTests {
  private struct Pair {
    let rig: MovingClockSpace
    let parent: SessionID
    let task: SessionID

    var store: SessionStore { rig.store }

    init() async throws {
      rig = try MovingClockSpace()
      parent = try await rig.store.createSession(
        group: .shared,
        title: "parent", kind: .agent, createdBy: "morgan", model: .test,
      )
      task = try await rig.store.createSession(
        group: .shared,
        title: "task", kind: .task, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test),
      )
    }

    func request(_ id: String, deadline: Date? = nil) async throws -> MessageDelivery {
      try await store.openRequest(
        on: task, from: parent, messageID: MessageID(id), text: "do the thing", deadline: deadline,
      )
    }

    // The queue is what a session was shown; the fold reads only drained rows.
    func drain(_ session: SessionID) async throws {
      _ = try await store.drainQueue(session)
    }
  }

  @Test func `a request opens one duty and reaches the task`() async throws {
    let pair = try await Pair()
    let delivery = try await pair.request("r1")
    #expect(delivery.enqueued == [pair.task])
    #expect(delivery.message.kind == .request)
    #expect(delivery.message.requestID == RequestID("r1"))
    try await pair.drain(pair.task)
    #expect(try await pair.store.settleState(pair.task).openRequests.keys.map(\.rawValue) == ["r1"])
  }

  @Test func `a second request while one is open is refused`() async throws {
    let pair = try await Pair()
    _ = try await pair.request("r1")
    try await pair.drain(pair.task)
    await #expect(throws: SessionStoreError.requestAlreadyOpen("r1")) {
      _ = try await pair.request("r2")
    }
  }

  @Test func `only the parent may open a request`() async throws {
    let pair = try await Pair()
    let stranger = try await pair.store.createSession(
      group: .shared,
      title: "stranger", kind: .agent, createdBy: "morgan", model: .test,
    )
    await #expect(throws: SessionStoreError.notTheParent(pair.task.rawValue)) {
      _ = try await pair.store.openRequest(
        on: pair.task, from: stranger, messageID: MessageID("r1"), text: "hi", deadline: nil,
      )
    }
  }

  @Test func `progress reaches the parent and leaves the request open, final closes it`() async throws {
    let pair = try await Pair()
    _ = try await pair.request("r1")
    try await pair.drain(pair.task)

    let progress = try await pair.store.report(
      pair.task, request: .init("r1"), kind: .progress, messageID: MessageID("p1"), text: "halfway",
    )
    #expect(progress.enqueued == [pair.parent])
    #expect(progress.message.kind == .progress)
    #expect(try await pair.store.settleState(pair.task).openRequests.count == 1)

    let final = try await pair.store.report(
      pair.task, request: .init("r1"), kind: .final, messageID: MessageID("f1"), text: "done",
    )
    #expect(final.enqueued == [pair.parent])
    #expect(try await pair.store.settleState(pair.task).openRequests.isEmpty)

    // A second brief is legal once the first is answered.
    _ = try await pair.request("r2")
  }

  @Test func `a report against an unknown request is refused`() async throws {
    let pair = try await Pair()
    await #expect(throws: SessionStoreError.unknownRequest("nope")) {
      _ = try await pair.store.report(
        pair.task, request: .init("nope"), kind: .final, messageID: MessageID("f1"), text: "done",
      )
    }
  }

  @Test func `a kernel task settling with its request open arms no park row`() async throws {
    let pair = try await Pair()
    _ = try await pair.request("r1")
    try await pair.drain(pair.task)

    _ = try await pair.store.appendAssistant(
      pair.task, attemptID: UUID(), message: SessionFix.assistant("thinking"), metadata: SessionFix.metadata,
    )
    #expect(try await pair.store.armedSubscriptions(pair.task).isEmpty, "the loop schedules its own park wake")
    #expect(try await pair.store.hydrate(pair.task).undrained.isEmpty)
  }

  @Test func `park reminders back off 1 then 5 minutes`() async throws {
    let pair = try await Pair()
    _ = try await pair.request("r1")
    try await pair.drain(pair.task)
    let start = pair.rig.store.dateGen.now

    _ = try await pair.store.enqueue(pair.task, input: .notification(.init(
      id: UUID(), timestamp: start, kind: .parkReminder,
      subscriptionID: .park(.init("r1")), requestID: .init("r1"), content: .init(text: "nudge"),
    )))
    try await pair.drain(pair.task)
    var open = try #require(try await pair.store.settleState(pair.task).openRequests[RequestID("r1")])
    #expect(open.parkReminderCount == 1)
    #expect(ParkBackoff.nextFire(after: open, now: start) == start.addingTimeInterval(60))

    pair.rig.advance(120)
    let second = pair.rig.store.dateGen.now
    _ = try await pair.store.enqueue(pair.task, input: .notification(.init(
      id: UUID(), timestamp: second, kind: .parkReminder,
      subscriptionID: .park(.init("r1")), requestID: .init("r1"), content: .init(text: "nudge"),
    )))
    try await pair.drain(pair.task)
    open = try #require(try await pair.store.settleState(pair.task).openRequests[RequestID("r1")])
    #expect(open.parkReminderCount == 2)
    #expect(ParkBackoff.nextFire(after: open, now: second) == second.addingTimeInterval(300))
  }

  @Test func `a deadline arms the parent's own subscription and a final cancels it`() async throws {
    let pair = try await Pair()
    let deadline = fixedDate.addingTimeInterval(3600)
    _ = try await pair.request("r1", deadline: deadline)
    #expect(try await pair.store.armedSubscriptions(pair.parent).map(\.slot.id.rawValue) == ["deadline.r1"])

    try await pair.drain(pair.task)
    _ = try await pair.store.report(
      pair.task, request: .init("r1"), kind: .final, messageID: MessageID("f1"), text: "done",
    )
    #expect(try await pair.store.armedSubscriptions(pair.parent).isEmpty)
  }

  @Test func `a deadline expiry writes the parent a notification`() async throws {
    let pair = try await Pair()
    let deadline = fixedDate.addingTimeInterval(3600)
    _ = try await pair.request("r1", deadline: deadline)
    try await pair.store.recordRequestDeadline(
      parent: pair.parent, task: pair.task, request: .init("r1"), deadline: deadline,
    )
    let rows = try await pair.store.notifications(recipient: Notifications.ownerRecipient)
    #expect(rows.map(\.kind) == [.requestDeadline])
    #expect(rows[0].source == pair.parent.rawValue)
  }

  @Test func `an errored task with an open request notifies its parent instead of faking a final`() async throws {
    let pair = try await Pair()
    _ = try await pair.request("r1")
    try await pair.drain(pair.task)

    var signals = pair.store.workSignals().makeAsyncIterator()
    try await pair.store.markErrored(pair.task, message: "boom")
    #expect(await signals.next() == pair.parent, "the parent is woken, not just written to")
    let rows = try await pair.store.notifications(recipient: Notifications.ownerRecipient)
    #expect(rows.map(\.kind) == [.childFailed])
    #expect(rows[0].payload.contains("boom"))
    #expect(try await pair.store.settleState(pair.task).openRequests.count == 1)

    let hydration = try await pair.store.hydrate(pair.parent)
    guard case let .notification(notification) = hydration.undrained.last?.input.transcriptItem else {
      Issue.record("the parent is told its child failed")
      return
    }
    #expect(notification.kind == .childFailed)
  }
}
