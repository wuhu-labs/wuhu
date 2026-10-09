import Clocks
import ControlledTime
import Dependencies
import Foundation
import GRDB
import JSONValue
import Logging
import SessionDomain
@testable import SessionTools
@_spi(SessionObservation) @testable import SpaceCore
import SpaceFS
import Testing

private func runningFiring<R>(
  _ space: Space,
  log: Logger? = nil,
  configure: (inout SubscriptionFiring) -> Void = { _ in },
  _ body: (Box<[SessionID]>) async throws -> R,
) async throws -> R {
  var firing = SubscriptionFiring(space: space)
  if let log { firing.log = log }
  configure(&firing)
  let service = firing
  let signals = space.sessions.workSignals()
  let signaled = Box<[SessionID]>([])
  return try await withThrowingTaskGroup(of: Void.self, returning: R.self) { group in
    group.addTask { await service.run() }
    group.addTask {
      for await session in signals {
        signaled.withLock { $0.append(session) }
      }
    }
    let result = try await body(signaled)
    group.cancelAll()
    return result
  }
}

private func tablePath(_ raw: String) throws -> SpacePath {
  try SpacePath(validating: raw)
}

private func tracingSpace(_ executed: @escaping @Sendable (String) -> Void) throws -> Space {
  var configuration = Space.makeConfiguration()
  configuration.prepareDatabase { db in
    db.trace { event in
      if case let .statement(statement) = event { executed(statement.sql) }
    }
  }
  return try Space.temporary(configuration: configuration, trace: executed)
}

private func observationNotifications(_ space: Space, session: SessionID) async throws -> [SystemNotification] {
  try await space.sessions.hydrate(session).undrained.compactMap { entry in
    guard case let .notification(notification) = entry.input, notification.kind == .spaceObservation else {
      return nil
    }
    return notification
  }
}

@Suite struct SubscriptionTests {
  @Test func startOverKeepsLiveObservationCronOneShotAndRequestDeadline() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let child = try await space.sessions.createSession(group: .shared, title: "child", kind: .task, parent: session, createdBy: session.rawValue, executor: try await space.sessions.record(session).executor)
      let watched = try tablePath("/restart.table")
      _ = try await space.createTable(watched, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      guard case let .observe(observation) = try await world.run("observe", .object(["sql": "SELECT n FROM \"/restart.table\"", "throttle_seconds": 1])) else { throw Mismatch("observe failed") }
      _ = try await world.run("timer", .object(["message": "cron survives", "cron": "* * * * *"]))
      _ = try await world.run("timer", .object(["message": "once survives", "in_seconds": 120]))
      _ = try await space.sessions.openRequest(on: child, from: session, messageID: .init("restart-duty"), text: "still owed", deadline: anchor.addingTimeInterval(120))
      _ = try await space.sessions.drainQueue(child)
      _ = try await space.sessions.enqueue(session, input: .message(.init(id: UUID(), messageID: .init("queued"), conversationID: .init("ch1"), sender: .init(id: "morgan", timeZone: TimeZone(identifier: "UTC")!), timestamp: anchor, content: .init(text: "queued before Start over"))))
      try await space.sessions.markInterrupted(session)
      let before = try await space.sessions.armedSubscriptions(session)
      try await runningFiring(space) { nudged in
        try await time.asleep("one-shot and deadline are armed", dueIn: 120)
        _ = try await space.sessions.restart(session, note: "catch up")
        #expect(try await space.sessions.armedSubscriptions(session) == before)
        let hydration = try await space.sessions.hydrate(session)
        #expect(hydration.undrained.count == 1)
        #expect(hydration.record.work == .hasWork)
        #expect(try await space.sessions.transcript(session).environment.tools.subscriptions.count == 4)
        _ = try await space.sessions.drainQueue(session)
        try await until("Start over posts a work signal") { nudged.value.contains(session) }
        _ = try await space.mutateRows(watched, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await until("the existing observation still fires") { try await observationNotifications(space, session: session).count == 1 }
        #expect(try await observationNotifications(space, session: session).first?.subscriptionID == observation.subscriptionID)
        await time.advance(by: 121)
        try await untilAdvancing("cron, one-shot and request deadline still fire", time) {
          let entries = try await space.sessions.hydrate(session).undrained
          let notifications = entries.compactMap { entry -> SystemNotification? in
            guard case let .notification(notification) = entry.input else { return nil }
            return notification
          }
          return notifications.contains { $0.content.text == "cron survives" }
            && notifications.contains { $0.content.text == "once survives" }
            && notifications.contains { $0.kind == .requestDeadline && $0.requestID == .init("restart-duty") }
        }
        #expect(try await space.sessions.armedSubscriptions(session).count == 2)
        #expect(try await space.sessions.settleState(child).openRequests[.init("restart-duty")] != nil)
        await time.advance(by: 60)
        try await untilAdvancing("cron fires again", time) {
          try await space.sessions.hydrate(session).undrained.filter {
            guard case let .notification(notification) = $0.input else { return false }
            return notification.content.text == "cron survives"
          }.count >= 2
        }
      }
    }
  }

  @Test func oneShotTimerFiresEnqueuesAndRetiresItsSlot() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      try await runningFiring(space) { nudged in
        guard case let .timer(armed) = try await world.run(
          "timer", .object(["message": "check the build", "in_seconds": 60]),
        ) else { throw Mismatch("timer arming failed") }

        await time.advance(by: 59)
        try await holds("no early fire") {
          try await space.sessions.hydrate(session).undrained.isEmpty
        }

        await time.advance(by: 3)
        try await untilAdvancing("the timer fires", time) {
          try await space.sessions.hydrate(session).undrained.count == 1
        }

        let undrained = try await space.sessions.hydrate(session).undrained
        guard case let .notification(fired)? = undrained.first?.input else {
          throw Mismatch("expected one fired notification, got \(undrained)")
        }
        #expect(fired.kind == .timer)
        #expect(fired.subscriptionID == armed.subscriptionID)
        #expect(fired.endsSubscription, "a one-shot fire must retire the subscription in the fold")
        #expect(fired.content.text == "check the build")
        #expect(try await space.sessions.armedSubscriptions().isEmpty, "the durable slot is retired")
        try await until("the work signal lands") { nudged.value.contains(session) }

        world.state.apply(delivered: .notification(fired))
        #expect(world.state.subscriptions[armed.subscriptionID] == nil)
      }
    }
  }

  @Test func cronTimerReschedulesAfterEachFire() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      try await runningFiring(space) { _ in
        guard case .timer = try await world.run(
          "timer", .object(["message": "tick", "cron": "*/5 * * * *"]),
        ) else { throw Mismatch("cron arming failed") }

        await time.advance(by: 5 * 60 + 1)
        try await untilAdvancing("the first cron fire", time) {
          try await space.sessions.hydrate(session).undrained.count == 1
        }
        #expect(try await space.sessions.armedSubscriptions().count == 1, "a cron timer survives its fire")

        await time.advance(by: 5 * 60)
        try await untilAdvancing("the second cron fire", time) {
          try await space.sessions.hydrate(session).undrained.count == 2
        }
        let afterSecond = try await space.sessions.hydrate(session).undrained
        if case let .notification(second)? = afterSecond.last?.input {
          #expect(!second.endsSubscription)
        }
      }
    }
  }

  @Test func jitteredCronDayFiresEachOfItsNinetySixSlotsExactlyOnce() async throws {
    let start = Date(timeIntervalSince1970: 1_790_726_400)
    let clock = LateWakeClock(anchor: start)
    try await withToolDeps { _ in
      try await withDependencies {
        $0.continuousClock = AnyClock(clock)
        $0.date = DateGenerator { clock.date }
      } operation: {
        let space = try Space.inMemory()
        let session = try await makeSession(space)
        var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
        try await runningFiring(space) { _ in
          guard case let .timer(timer) = try await world.run(
            "timer", .object(["message": "quarter hour", "cron": "*/15 * * * *"]),
          ) else { throw Mismatch("cron arming failed") }
          for slot in 1 ... 96 {
            let due = Date(timeIntervalSince1970: start.timeIntervalSince1970 + Double(slot * 900))
            let registered = try #require(await space.sessions.armedSubscriptions(session).first)
            #expect(registered.nextFireAt == due)
            try await until("slot \(slot) is asleep") { clock.isSleeping(until: due) }
            let jitter = [0.0001014, 0.9990734, 0.0002, 2.125][slot % 4]
            let wake = due.addingTimeInterval(jitter)
            clock.advance(to: wake)
            try await until("slot \(slot) fires and advances") {
              let row = try await space.sessions.armedSubscriptions(session).first
              let count = try await space.sessions.hydrate(session).undrained.count
              return row?.nextFireAt == due.addingTimeInterval(900) && count == slot
            }
            let entries = try await space.sessions.hydrate(session).undrained
            guard case let .notification(notification) = entries.last!.input else {
              throw Mismatch("expected timer notification")
            }
            #expect(notification.id == UUID.deterministic("timer", session.rawValue, timer.subscriptionID.rawValue, String(due.timeIntervalSince1970)))
            #expect(!notification.endsSubscription)
            #expect(abs(notification.timestamp.timeIntervalSince(wake)) < 0.001)
            #expect(try await space.sessions.hydrate(session).undrained.count == slot)
          }
          try await holds("no duplicates after the simulated day") {
            try await space.sessions.hydrate(session).undrained.count == 96
          }
          let entries = try await space.sessions.hydrate(session).undrained
          #expect(Set(entries.compactMap { entry -> UUID? in
            guard case let .notification(notification) = entry.input else { return nil }
            return notification.id
          }).count == 96)
        }
      }
    }
  }

  @Test func legacyOffMinuteDueFiresOnceThenAdvancesExactly() async throws {
    try await withToolDeps { time in
      let wake = Date(timeIntervalSinceReferenceDate: 812_446_259.9990734)
      await time.advance(to: wake)
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let slot = SubscriptionSlot(id: .init("timer.legacy"), kind: .timer(.cron("*/15 * * * *"), message: "legacy"))
      let due = Date(timeIntervalSince1970: 1_790_753_459.999)
      try await space.sessions.armSubscription(session, slot: slot, nextFireAt: due)
      try await runningFiring(space) { _ in
        try await until("legacy due fires and advances") {
          try await space.sessions.armedSubscriptions(session).first?.nextFireAt == Date(timeIntervalSince1970: 1_790_754_300)
        }
        try await holds("legacy slot only fires once") {
          try await space.sessions.hydrate(session).undrained.count == 1
        }
        try await time.asleep("the exact next slot", dueIn: Date(timeIntervalSince1970: 1_790_754_300).timeIntervalSince(wake))
        await time.advance(to: Date(timeIntervalSince1970: 1_790_754_300.001))
        try await until("next exact slot fires") {
          try await space.sessions.hydrate(session).undrained.count == 2
        }
      }
    }
  }

  @Test func recurringFireAdvancesFromDueEvenWhenWallClockIsBehind() async throws {
    try await withToolDeps { time in
      try await withDependencies { $0.date = .constant(anchor) } operation: {
        let space = try Space.inMemory()
        let session = try await makeSession(space)
        let due = anchor.addingTimeInterval(900)
        try await space.sessions.armSubscription(
          session,
          slot: .init(id: .init("timer.backward"), kind: .timer(.cron("*/15 * * * *"), message: "tick")),
          nextFireAt: due,
        )
        try await runningFiring(space) { _ in
          try await time.asleep("first timer with frozen wall clock", dueIn: 900)
          await time.advance(to: anchor.addingTimeInterval(900.001))
          try await until("reschedule advances past due, not frozen now") {
            try await space.sessions.armedSubscriptions(session).first?.nextFireAt == due.addingTimeInterval(900)
          }
          #expect(try await space.sessions.hydrate(session).undrained.count == 1)
          try await time.asleep("next timer is armed", dueIn: 1800)
        }
      }
    }
  }

  @Test func unchangedStoredDueStopsInsteadOfRetainingOrLoopingTheFinishedTask() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let due = anchor.addingTimeInterval(900)
      try await space.sessions.armSubscription(
        session,
        slot: .init(id: .init("timer.stuck"), kind: .timer(.cron("*/15 * * * *"), message: "tick")),
        nextFireAt: due,
      )
      let writer = await space.writer
      try await writer.write { db in
        try db.execute(sql: """
        CREATE TRIGGER stuck_due AFTER UPDATE OF next_fire_at ON session_subscriptions
        BEGIN
          UPDATE session_subscriptions SET next_fire_at = OLD.next_fire_at
          WHERE session_id = NEW.session_id AND subscription_id = NEW.subscription_id;
        END;
        """)
      }
      let errors = Box<[String]>([])
      let log = Logger(label: "test.firing") { _ in FiringLogHandler(errors: errors) }
      try await runningFiring(space, log: log) { _ in
        try await time.asleep("stuck timer", dueIn: 900)
        await time.advance(to: due.addingTimeInterval(0.001))
        try await until("one fire finishes") {
          try await space.sessions.hydrate(session).undrained.count == 1
        }
        try await until("the completed task logs the invariant failure") { errors.value.count == 1 }
        #expect(errors.value[0].contains("timer.stuck"))
        #expect(errors.value[0].contains("did not advance"))
        await time.advance(to: due.addingTimeInterval(3600))
        try await holds("a non-advancing row is not re-fired") {
          try await space.sessions.hydrate(session).undrained.count == 1 && time.sleepCount == 0
        }
        #expect(errors.value.count == 1)
      }
    }
  }

  @Test func rejectedNonAdvancingRescheduleStopsTheArmingWithoutRetry() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let due = anchor.addingTimeInterval(900)
      try await space.sessions.armSubscription(
        session,
        slot: .init(id: .init("timer.rejected"), kind: .timer(.cron("*/15 * * * *"), message: "tick")),
        nextFireAt: due,
      )
      let messages = Box<[String]>([])
      let attempts = Box(0)
      let log = Logger(label: "test.rejected") { _ in FiringLogHandler(errors: messages) }
      try await runningFiring(space, log: log, configure: { firing in
        firing.nextCronFire = { _, _ in
          attempts.withLock { $0 += 1 }
          return due
        }
      }) { _ in
        try await time.wake("the rejected timer", after: 900)
        try await until("the typed non-advancing error is logged") { messages.value.count == 1 }
        #expect(messages.value[0].contains("timer.rejected"))
        #expect(messages.value[0].contains("reschedule did not advance stored due time"))
        #expect(try await space.sessions.hydrate(session).undrained.isEmpty)
        #expect(try await space.sessions.armedSubscriptions(session).first?.nextFireAt == due)
        await time.advance(by: 3600)
        try await holds("the rejected arming never retries") {
          attempts.value == 1 && messages.value.count == 1 && time.sleepCount == 0
        }
        #expect(try await space.sessions.hydrate(session).undrained.isEmpty)
      }
    }
  }

  @Test(arguments: [false, true])
  func deadlineDeliveryFailureRetriesBothNotificationsAtomically(ownerFailure: Bool) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let parent = try await makeSession(space)
      let task = try await space.sessions.createSession(
        group: .shared, title: "deadline child", kind: .task, parent: parent, createdBy: parent.rawValue,
        executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
      )
      let due = anchor.addingTimeInterval(900)
      let request = RequestID("request.retry")
      let slot = SubscriptionSlot(id: .deadline(request), kind: .requestDeadline(request: request, task: task))
      try await space.sessions.armSubscription(parent, slot: slot, nextFireAt: due)
      let remaining = Box(1)
      try await installTransientWriteFailure(space, remaining: remaining, table: ownerFailure ? "notifications" : "session_queue")
      let messages = Box<[String]>([])
      let log = Logger(label: "test.deadline-retry") { _ in FiringLogHandler(errors: messages) }
      let writer = await space.writer
      func ownerDeadlines() async throws -> [(recipient: String, source: String, payload: String)] {
        try await writer.read { db in
          try Row.fetchAll(db, sql: "SELECT * FROM notifications WHERE kind = 'request_deadline'").map {
            (recipient: $0["recipient"], source: $0["source"], payload: $0["payload"])
          }
        }
      }
      try await runningFiring(space, log: log) { nudged in
        try await time.wake("the request deadline", after: 900)
        try await until("the deadline delivery failure is logged") { messages.value.count == 1 }
        #expect(messages.value[0].contains("injected transient write failure"))
        #expect(try await space.sessions.hydrate(parent).undrained.isEmpty)
        #expect(try await ownerDeadlines().isEmpty)
        #expect(try await space.sessions.armedSubscriptions(parent).first?.nextFireAt == due)
        try await time.asleep("deadline delivery retry", dueIn: 1)
        try await holds("deadline failure does not spin") { remaining.value == 0 && nudged.value.isEmpty }
        await time.advance(by: 1)
        try await until("both deadline notifications commit") {
          let queued = try await space.sessions.hydrate(parent).undrained.count
          let owners = try await ownerDeadlines().count
          return queued == 1 && owners == 1
        }
        let entries = try await space.sessions.hydrate(parent).undrained
        guard case let .notification(notification) = entries[0].input else { throw Mismatch("missing deadline delivery") }
        #expect(notification.id == UUID.deterministic("deadline", parent.rawValue, request.rawValue))
        #expect(notification.kind == .requestDeadline)
        #expect(notification.requestID == request)
        #expect(notification.endsSubscription)
        let owner = try #require(await ownerDeadlines().first)
        #expect(owner.recipient == "owner")
        #expect(owner.source == parent.rawValue)
        let payload = try JSONDecoder().decode(Notifications.RequestDeadlinePayload.self, from: Data(owner.payload.utf8))
        #expect(payload.sessionID == task.rawValue)
        #expect(payload.parent == parent.rawValue)
        #expect(payload.requestID == request.rawValue)
        #expect(payload.deadlineAt == due.timeIntervalSince1970)
        #expect(try await space.sessions.armedSubscriptions(parent).isEmpty)
        try await until("deadline work signal is emitted") { nudged.value.contains(parent) }
        await time.advance(by: 3600)
        try await holds("the recovered deadline is not duplicated") {
          let queued = try await space.sessions.hydrate(parent).undrained.count
          let owners = try await ownerDeadlines().count
          return queued == 1 && owners == 1 && messages.value.count == 1
        }
        await #expect(throws: (any Error).self) {
          try await space.sessions.fireSubscription(parent, subscriptionID: slot.id, notification: notification, advance: .retire)
        }
        #expect(try await ownerDeadlines().count == 1)
      }
    }
  }

  @Test(arguments: [false, true], [1, 8])
  func transientFireWritesRetryWithBoundedBackoff(cron: Bool, failures: Int) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let due = anchor.addingTimeInterval(900)
      let schedule: TimerSchedule = cron ? .cron("*/15 * * * *") : .oneShot(due)
      let slot = SubscriptionSlot(id: .init("timer.retry"), kind: .timer(schedule, message: "retry tick"))
      try await space.sessions.armSubscription(session, slot: slot, nextFireAt: due)
      let remaining = Box(failures)
      try await installTransientQueueFailure(space, remaining: remaining)
      let messages = Box<[String]>([])
      let log = Logger(label: "test.retry") { _ in FiringLogHandler(errors: messages) }
      try await runningFiring(space, log: log) { _ in
        try await time.asleep("initial fire", dueIn: 900)
        await time.advance(to: due.addingTimeInterval(0.000001))
        for attempt in 0 ..< failures {
          try await until("failure \(attempt + 1) is recorded") { messages.value.count == attempt + 1 }
          #expect(messages.value.last!.contains("injected transient queue write failure"))
          #expect(!messages.value.last!.contains("did not advance"))
          #expect(try await space.sessions.hydrate(session).undrained.isEmpty)
          #expect(try await space.sessions.armedSubscriptions(session).first?.nextFireAt == due)
          let backoff = Double(min(1 << attempt, 60))
          try await time.asleep("retry \(attempt + 1) backoff", dueIn: backoff)
          try await holds("retry does not spin while the clock is still") { remaining.value == failures - attempt - 1 }
          await time.advance(by: backoff)
        }
        try await until("retry commits exactly one fire") {
          try await space.sessions.hydrate(session).undrained.count == 1
        }
        #expect(remaining.value == 0)
        let notifications = try await space.sessions.hydrate(session).undrained
        guard case let .notification(notification) = notifications[0].input else { throw Mismatch("missing timer delivery") }
        #expect(notification.id == UUID.deterministic("timer", session.rawValue, slot.id.rawValue, String(due.timeIntervalSince1970)))
        #expect(notification.endsSubscription == !cron)
        if cron {
          #expect(try await space.sessions.armedSubscriptions(session).first?.nextFireAt == due.addingTimeInterval(900))
        } else {
          #expect(try await space.sessions.armedSubscriptions(session).isEmpty)
        }
        try await holds("no duplicate retry delivery") {
          try await space.sessions.hydrate(session).undrained.count == 1 && messages.value.count == failures
        }
      }
    }
  }

  @Test func observationWriteFailureRetriesWithoutRetiringTheSlot() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      try await space.sessions.armSubscription(session, slot: .init(id: .init("obs.retry"), kind: .observe(sql: "SELECT 1", throttleSeconds: 1)))
      let remaining = Box(1)
      try await installTransientQueueFailure(space, remaining: remaining)
      let messages = Box<[String]>([])
      let log = Logger(label: "test.observation-retry") { _ in FiringLogHandler(errors: messages) }
      try await runningFiring(space, log: log) { _ in
        try await until("observation write failure logs the actual cause") { messages.value.count == 1 }
        #expect(messages.value[0].contains("injected transient queue write failure"))
        #expect(try await observationNotifications(space, session: session).isEmpty)
        #expect(try await space.sessions.armedSubscriptions(session).count == 1)
        try await time.wake("observation delivery retry", after: 1)
        try await until("one observation delivery recovers") {
          try await observationNotifications(space, session: session).count == 1
        }
        let notification = try #require(await observationNotifications(space, session: session).first)
        #expect(!notification.endsSubscription)
        #expect(try await space.sessions.armedSubscriptions(session).count == 1)
        try await holds("retry does not duplicate the observation") {
          try await observationNotifications(space, session: session).count == 1
        }
      }
    }
  }

  @Test(arguments: [false, true])
  func observationStreamEndOrOperationalFailureRetriesAfterBackoff(readFailure: Bool) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      try await space.sessions.armSubscription(session, slot: .init(id: .init("obs.ended"), kind: .observe(sql: "SELECT 1", throttleSeconds: 1)))
      let starts = Box(0)
      let messages = Box<[String]>([])
      let log = Logger(label: "test.observation-ended") { _ in FiringLogHandler(errors: messages) }
      try await runningFiring(space, log: log, configure: { firing in
        let live = firing.observationStream
        firing.observationStream = { space, session, sql in
          let count = starts.withLock { $0 += 1; return $0 }
          if count == 1 {
            return AsyncThrowingStream { stream in
              if readFailure {
                stream.finish(throwing: DatabaseError(resultCode: .SQLITE_IOERR, message: "transient observation read failure"))
              } else {
                stream.finish()
              }
            }
          }
          return try await live(space, session, sql)
        }
      }) { _ in
        try await until("clean stream end is recorded") { messages.value.count == 1 }
        #expect(messages.value[0].contains(readFailure ? "transient observation read failure" : "observationStreamEnded"))
        try await time.asleep("ended stream retry", dueIn: 1)
        #expect(starts.value == 1)
        await time.advance(by: 1)
        try await until("observation restarts and delivers") {
          try await observationNotifications(space, session: session).count == 1
        }
        #expect(starts.value == 2)
        #expect(try await space.sessions.armedSubscriptions(session).count == 1)
      }
    }
  }

  @Test func cancelToolsCheckKindAndRetireTheSlot() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      guard case let .timer(timer) = try await world.run(
        "timer", .object(["message": "x", "in_seconds": 600]),
      ) else { throw Mismatch("timer arming failed") }

      let wrongKind = try await world.run(
        "cancel_observation", .object(["subscription_id": .string(timer.subscriptionID.rawValue)]),
      )
      #expect(try failureMessage(wrongKind).contains("cancel_timer"))

      let unknown = try await world.run("cancel_timer", .object(["subscription_id": "timer.nope"]))
      #expect(try failureMessage(unknown).contains("unknown subscription"))

      guard case .cancelTimer = try await world.run(
        "cancel_timer", .object(["subscription_id": .string(timer.subscriptionID.rawValue)]),
      ) else { throw Mismatch("cancel failed") }
      #expect(try await space.sessions.armedSubscriptions().isEmpty)
      #expect(world.state.subscriptions.isEmpty, "the fold retires the cancelled subscription")

      // A crash-retry of the cancel: the slot is already gone but the fold
      // (result never committed) still shows the subscription — idempotent.
      var stale = ToolWorld(executor: ToolExecutor(space: space), session: session)
      _ = try await stale.run("timer", .object(["message": "y", "in_seconds": 600]), id: "tc-t2")
      try await space.sessions.cancelSubscription(session, subscriptionID: .timer(.init("tc-t2")))
      guard case .cancelTimer = try await stale.run(
        "cancel_timer", .object(["subscription_id": .string(SubscriptionID.timer(.init("tc-t2")).rawValue)]),
      ) else { throw Mismatch("retry cancel must absorb the already-deleted slot") }
    }
  }

  @Test func rearmingByTheSameToolCallIsIdempotent() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      let first = try await world.run("timer", .object(["message": "x", "in_seconds": 60]), id: "tc-timer")
      let retried = try await world.retry("timer", .object(["message": "x", "in_seconds": 60]), id: "tc-timer")
      guard case let .timer(a) = first, case let .timer(b) = retried else {
        throw Mismatch("timer arming failed")
      }
      #expect(a.subscriptionID == b.subscriptionID)
      #expect(try await space.sessions.armedSubscriptions().count == 1, "the retry re-arms the same slot")
    }
  }

  @Test func brokenObservationNotifiesOnceAndRetires() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      // Armed directly at the store: the executor's sandbox validation would
      // reject this SQL, but a table can vanish after arming.
      try await space.sessions.armSubscription(
        session,
        slot: .init(id: .init("obs.broken"), kind: .observe(sql: "SELECT * FROM nope", throttleSeconds: 1)),
      )
      try await runningFiring(space) { _ in
        await time.advance(by: 2)
        try await untilAdvancing("the error notification lands", time) {
          try await space.sessions.hydrate(session).undrained.count == 1
        }
        let undrained = try await space.sessions.hydrate(session).undrained
        guard case let .notification(fired)? = undrained.first?.input else {
          throw Mismatch("expected an error notification")
        }
        #expect(fired.endsSubscription)
        #expect(fired.content.text.contains("cancelled"))
        #expect(try await space.sessions.armedSubscriptions().isEmpty)
      }
    }
  }

  @Test func timerArgumentsWantExactlyOneSchedule() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))
      let both = try await world.run(
        "timer", .object(["message": "x", "in_seconds": 5, "cron": "* * * * *"]),
      )
      #expect(try failureMessage(both).contains("exactly one"))
      let neither = try await world.run("timer", .object(["message": "x"]))
      #expect(try failureMessage(neither).contains("exactly one"))
      let badCron = try await world.run("timer", .object(["message": "x", "cron": "not a cron"]))
      #expect(try failureMessage(badCron).contains("cron"))
    }
  }

  @Test func anObservationSleepsUntilItsOwnTableChangesAndDeliversTheLatest() async throws {
    try await withToolDeps { time in
      let executed = Box<[String]>([])
      let space = try tracingSpace { sql in executed.withLock { $0.append(sql) } }
      let watched = try tablePath("/watched.table")
      let unrelated = try tablePath("/unrelated.table")
      let header = TableHeader(columns: [TableColumn(name: "n", type: .integer)])
      _ = try await space.createTable(watched, header: header, in: .shared, acting: .shared)
      _ = try await space.createTable(unrelated, header: header, in: .shared, acting: .shared)
      _ = try await space.mutateRows(watched, [.insert([.integer(0)])], in: .shared, acting: .shared)
      let ids = try await space.query("SELECT id FROM \"/watched.table\"", as: .shared(.anonymous))
      guard case let .integer(rowID) = ids.rows[0][0] else { throw Mismatch("missing row id") }

      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      let sql = "SELECT n FROM \"/watched.table\" ORDER BY n"
      guard case let .observe(armed) = try await world.run(
        "observe",
        .object(["sql": .string(sql), "throttle_seconds": 10]),
      ) else { throw Mismatch("observe arming failed") }

      func ran() -> (query: Int, registry: Int) {
        let statements = executed.value
        return (
          statements.filter { $0 == sql }.count,
          statements.filter { $0.hasPrefix("SELECT * FROM session_subscriptions") }.count,
        )
      }

      // The change lands while nothing is watching: a recovered observation
      // compares the snapshot against its persisted marker, not against silence.
      _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(1)])], in: .shared, acting: .shared)
      try await runningFiring(space) { _ in
        try await until("the recovered observation notifies") {
          try await space.sessions.hydrate(session).undrained.count == 1
        }
        let recovered = try #require(await observationNotifications(space, session: session).first)
        #expect(recovered.subscriptionID == armed.subscriptionID)
        #expect(!recovered.endsSubscription)
        #expect(recovered.content.text.contains(sql))

        await time.advance(by: 300)
        let idle = ran()
        try await holds("an idle observation runs no statements") { ran() == idle }

        _ = try await space.mutateRows(unrelated, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await holds("a write to another table wakes nothing") { ran() == idle }

        _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(2)])], in: .shared, acting: .shared)
        try await until("a write to the watched table delivers") {
          try await space.sessions.hydrate(session).undrained.count == 2
        }
        #expect(ran().query > idle.query)

        _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(3)])], in: .shared, acting: .shared)
        _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(4)])], in: .shared, acting: .shared)
        try await holds("changes inside the throttle window stay silent") {
          try await space.sessions.hydrate(session).undrained.count == 2
        }

        await time.advance(by: 11)
        try await untilAdvancing("the window ends with one delivery", time) {
          try await space.sessions.hydrate(session).undrained.count == 3
        }
        let delivered = try await observationNotifications(space, session: session)
        #expect(delivered.count == 3)
        #expect(delivered.last!.content.text.contains("[[4]]"))
        #expect(!delivered.last!.content.text.contains("[[3]]"), "the state it passed through is not news")
        #expect(Set(delivered.map(\.id)).count == 3)
      }
    }
  }
}

private struct FiringLogHandler: LogHandler {
  let errors: Box<[String]>
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    guard event.level >= .warning else { return }
    errors.withLock { $0.append(event.message.description) }
  }
}

private func installTransientQueueFailure(_ space: Space, remaining: Box<Int>) async throws {
  try await installTransientWriteFailure(space, remaining: remaining, table: "session_queue", message: "injected transient queue write failure")
}

private func installTransientWriteFailure(
  _ space: Space, remaining: Box<Int>, table: String, message: String = "injected transient write failure",
) async throws {
  let writer = await space.writer
  try await writer.write { db in
    db.add(function: DatabaseFunction("transient_queue_failure", argumentCount: 0) { _ in
      let fail = remaining.withLock { count in
        guard count > 0 else { return false }
        count -= 1
        return true
      }
      if fail { throw DatabaseError(resultCode: .SQLITE_BUSY, message: message) }
      return 0
    })
    try db.execute(sql: """
    CREATE TRIGGER transient_queue_write BEFORE INSERT ON \(table)
    BEGIN
      SELECT transient_queue_failure();
    END;
    """)
  }
}

// Unlike TestClock's stepped advance, one wake publishes the late wall time
// before releasing due sleepers, so firing and re-arming cannot run mid-advance.
private final class LateWakeClock: Clock, Sendable {
  typealias Instant = TestClock<Duration>.Instant
  let anchor: Date
  private struct Sleep: Sendable {
    let deadline: Instant
    let continuation: AsyncThrowingStream<Void, any Error>.Continuation
  }

  private struct State: Sendable {
    var now = Instant()
    var sleeps: [UUID: Sleep] = [:]
  }

  private let state = Box(State())

  init(anchor: Date) { self.anchor = anchor }
  var now: Instant { state.value.now }
  var minimumResolution: Duration { .nanoseconds(1) }
  var date: Date {
    let duration = Instant().duration(to: now).components
    return anchor.addingTimeInterval(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
  }

  func isSleeping(until due: Date) -> Bool {
    let deadline = Instant(offset: .seconds(due.timeIntervalSince(anchor)))
    return state.value.sleeps.values.contains {
      let delta = $0.deadline.duration(to: deadline)
      return delta > .milliseconds(-1) && delta < .milliseconds(1)
    }
  }

  func advance(to wake: Date) {
    let ready = state.withLock { state in
      state.now = Instant(offset: .seconds(wake.timeIntervalSince(anchor)))
      let ready = state.sleeps.filter { $0.value.deadline <= state.now }
      for id in ready.keys { state.sleeps[id] = nil }
      return Array(ready.values)
    }
    for sleep in ready { sleep.continuation.finish() }
  }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Void.self)
    let alreadyDue = state.withLock { state in
      guard deadline > state.now else { return true }
      state.sleeps[id] = Sleep(deadline: deadline, continuation: continuation)
      return false
    }
    if alreadyDue { continuation.finish() }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      for try await _ in stream {}
      try Task.checkCancellation()
    } onCancel: {
      self.state.withLock { $0.sleeps[id] = nil }
      continuation.finish(throwing: CancellationError())
    }
  }
}
