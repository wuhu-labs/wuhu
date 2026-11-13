import DeterministicDependencies
import Foundation
import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct RequestReportTests {
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

    func request(_ id: String) async throws -> MessageDelivery {
      try await store.openRequest(
        on: task, from: .session(parent), messageID: MessageID(id), text: "do the thing",
      )
    }

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
    #expect(try pair.store.openRequests(pair.task) == [OpenRequest(id: RequestID("r1"))])
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
        on: pair.task, from: .session(stranger), messageID: MessageID("r1"), text: "hi",
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
    #expect(try pair.store.openRequests(pair.task).count == 1)

    let final = try await pair.store.report(
      pair.task, request: .init("r1"), kind: .final, messageID: MessageID("f1"), text: "done",
    )
    #expect(final.enqueued == [pair.parent])
    #expect(try pair.store.openRequests(pair.task).isEmpty)

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

  @Test func `a parent watches its children while one is live`() async throws {
    let pair = try await Pair()
    let watched = {
      try await pair.store.deliverMail()
      return try pair.rig.space.cell.armedSubscriptions().filter { $0.owner == .session(pair.parent) }.map(\.slot.id.rawValue)
    }
    #expect(try await watched() == [SubscriptionSlot.childrenID.rawValue])

    _ = try await pair.store.archive(pair.task, grace: .seconds(60))
    #expect(try await watched().isEmpty)

    try await pair.store.unarchive(pair.task)
    #expect(try await watched() == [SubscriptionSlot.childrenID.rawValue])
  }
}
