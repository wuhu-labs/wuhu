import Foundation
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing

// A request's stall clock: the parent hears once when its task goes quiet
// with nothing to wait on, and hears again only after new progress.
@Suite struct RequestStallTests {
  private final class Rig: Sendable {
    let rig: MovingClockSpace
    let parent: SessionID
    let task: SessionID
    let request = RequestID("r1")
    private let elapsed = Mutex<TimeInterval>(0)

    var store: SessionStore { rig.store }
    var now: Date { fixedDate.addingTimeInterval(elapsed.withLock { $0 }) }

    init(stall: Double? = 600) async throws {
      rig = try MovingClockSpace()
      parent = try await rig.store.createSession(
        group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test,
      )
      task = try await rig.store.createSession(
        group: .shared, title: "task", kind: .task, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test),
      )
      _ = try await rig.store.openRequest(
        on: task, from: parent, messageID: MessageID(request.rawValue), text: "do the thing", deadline: nil, stallSeconds: stall,
      )
    }

    func at(_ seconds: TimeInterval) {
      let step = elapsed.withLock { old in
        defer { old = seconds }
        return seconds - old
      }
      rig.advance(step)
    }

    func slot() async throws -> ArmedSubscription? {
      try await store.armedSubscriptions(parent).first { $0.slot.id == .stall(request) }
    }

    func due() async throws -> Date? {
      try await slot()?.nextFireAt
    }

    // Checks at the given second and returns the alerts it produced.
    @discardableResult
    func check(_ seconds: TimeInterval, liveScripts: Set<SessionID> = []) async throws -> [SystemNotification] {
      at(seconds)
      try await store.checkRequestStall(parent, subscriptionID: .stall(request), now: now, liveScripts: liveScripts)
      return try await store.drainQueue(parent).items.compactMap { item in
        guard case let .notification(notification) = item, notification.kind == .requestStall else { return nil }
        return notification
      }
    }

    func inference(on session: SessionID, at seconds: TimeInterval) async throws {
      at(seconds)
      try await rig.space.recordInference(InferenceRecord(
        id: "inf-\(Int(seconds))", session: session, at: now, provider: "test", model: "test", effort: "medium",
        outcome: "ok", durationMs: 1000,
      ))
    }
  }

  private func time(_ seconds: TimeInterval) -> Date { fixedDate.addingTimeInterval(seconds) }

  @Test func `a silent task alerts once and new progress re-arms the alert`() async throws {
    let rig = try await Rig()
    #expect(try await rig.due() == time(600))

    #expect(try await rig.check(300).isEmpty)
    #expect(try await rig.due() == time(600))

    let alerts = try await rig.check(600)
    #expect(alerts.count == 1)
    #expect(alerts.first?.requestID == rig.request)
    #expect(alerts.first?.subscriptionID == .stall(rig.request))
    #expect(alerts.first?.content.text.contains("The task is idle.") == true)

    #expect(try await rig.check(1200).isEmpty)
    #expect(try await rig.check(1800).isEmpty)

    // Progress anywhere under the task counts: here its own child infers.
    let grandchild = try await rig.store.createSession(
      group: .shared, title: "sub", kind: .task, parent: rig.task, createdBy: rig.task.rawValue, executor: .kernel(.test),
    )
    try await rig.inference(on: grandchild, at: 1900)
    #expect(try await rig.check(1950).isEmpty)
    #expect(try await rig.due() == time(2501))
    #expect(try await rig.check(2501).count == 1)
    #expect(try await rig.check(3200).isEmpty)
  }

  @Test func `a task waiting on a script raises nothing while the script runs`() async throws {
    let rig = try await Rig()
    let incarnation = UUID()
    try await rig.store.beginWorkerOwnership(incarnation: incarnation)
    rig.at(300)
    try await rig.store.registerWorkerScript("ci-watch", session: rig.task, incarnation: incarnation)

    for second in stride(from: 600.0, through: 4200, by: 600) {
      #expect(try await rig.check(second).isEmpty)
    }

    // The script's update wakes the task, which is progress.
    try await rig.store.releaseWorkerScript("ci-watch", session: rig.task, incarnation: incarnation)
    try await rig.inference(on: rig.task, at: 4210)
    #expect(try await rig.check(4260).isEmpty)
    #expect(try await rig.check(4811).count == 1)
  }

  @Test func `a handler firing on a worker does not hold the clock`() async throws {
    let rig = try await Rig()
    let incarnation = UUID()
    try await rig.store.beginWorkerOwnership(incarnation: incarnation)
    try await rig.store.registerWorkerScript("handler-bridge-1", session: rig.task, incarnation: incarnation)
    try await rig.store.registerWorkerScript("handler-1", session: rig.task, incarnation: incarnation)
    #expect(try await rig.check(600).count == 1)
  }

  @Test func `a script running in this process holds the clock`() async throws {
    let rig = try await Rig()
    for second in stride(from: 600.0, through: 1800, by: 600) {
      #expect(try await rig.check(second, liveScripts: [rig.task]).isEmpty)
    }
    // Ended, it was a wait since the anchor, so the clock starts over.
    #expect(try await rig.check(1900).isEmpty)
    #expect(try await rig.due() == time(2500))
    #expect(try await rig.check(2500).count == 1)
  }

  @Test func `a wait stops the clock from its real start without resetting it`() async throws {
    let rig = try await Rig()
    #expect(try await rig.check(100).isEmpty)
    rig.at(200)
    _ = try await rig.store.armSubscription(
      rig.task, slot: .init(id: .init("timer.t1"), kind: .timer(.oneShot(time(1200)), message: "wake")), nextFireAt: time(1200),
    )
    // The check is due at 600, after the wait began at 200.
    #expect(try await rig.check(600).isEmpty)
    #expect(try await rig.check(1200).isEmpty)
    // 200 s ran before the wait and 1000 s were paused: 400 s remain.
    #expect(try await rig.due() == time(1600))
    #expect(try await rig.check(1600).count == 1)
  }

  @Test func `an armed observation or cron timer does not hold the clock`() async throws {
    let rig = try await Rig()
    _ = try await rig.store.armSubscription(
      rig.task, slot: .init(id: .init("obs.inbox"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30)), marker: "m",
    )
    _ = try await rig.store.armSubscription(
      rig.task, slot: .init(id: .init("timer.daily"), kind: .timer(.cron("0 9 * * *"), message: "daily")), nextFireAt: time(3600),
    )
    #expect(try await rig.check(600).count == 1)
  }

  @Test func `a one-shot timer holds the clock only until it is due`() async throws {
    let rig = try await Rig()
    _ = try await rig.store.armSubscription(
      rig.task, slot: .init(id: .init("timer.t1"), kind: .timer(.oneShot(time(1000)), message: "wake")), nextFireAt: time(1000),
    )
    #expect(try await rig.check(600).isEmpty)
    #expect(try await rig.due() == time(660))
    // A timer that is due but has not fired yet is no longer a wait; the
    // whole time since it was armed was paused.
    #expect(try await rig.check(1000).isEmpty)
    #expect(try await rig.due() == time(1600))
    #expect(try await rig.check(1599).isEmpty)
    #expect(try await rig.check(1600).count == 1)
  }

  @Test func `an inference open past the stall alerts as unknown`() async throws {
    let rig = try await Rig()
    _ = try await rig.store.drainQueue(rig.task)
    let alerts = try await rig.check(600)
    #expect(alerts.count == 1)
    #expect(alerts.first?.content.text.contains("unknown: inference open since") == true)
  }

  @Test func `the final report retires the clock`() async throws {
    let rig = try await Rig()
    _ = try await rig.store.drainQueue(rig.task)
    #expect(try await rig.slot() != nil)
    _ = try await rig.store.report(rig.task, request: rig.request, kind: .final, messageID: MessageID("f1"), text: "done")
    #expect(try await rig.slot() == nil)
  }

  @Test func `an archived task retires the clock at its next check`() async throws {
    let rig = try await Rig()
    _ = try await rig.store.archive(rig.task, grace: .seconds(60))
    #expect(try await rig.check(600).isEmpty)
    #expect(try await rig.slot() == nil)
  }

  @Test func `a replayed request re-arms a missing clock until it is closed`() async throws {
    let rig = try await Rig()
    try await rig.store.cancelSubscription(rig.parent, subscriptionID: .stall(rig.request))
    rig.at(300)
    func replay() async throws {
      _ = try await rig.store.openRequest(
        on: rig.task, from: rig.parent, messageID: MessageID(rig.request.rawValue), text: "do the thing", deadline: nil,
        stallSeconds: 600,
      )
    }
    try await replay()
    // The clock runs from the request's post, not from the replay.
    #expect(try await rig.due() == time(600))

    _ = try await rig.store.drainQueue(rig.task)
    _ = try await rig.store.report(rig.task, request: rig.request, kind: .final, messageID: MessageID("f1"), text: "done")
    try await replay()
    #expect(try await rig.slot() == nil)
  }

  @Test func `without a stall the request arms no clock`() async throws {
    let rig = try await Rig(stall: nil)
    #expect(try await rig.slot() == nil)
  }
}
