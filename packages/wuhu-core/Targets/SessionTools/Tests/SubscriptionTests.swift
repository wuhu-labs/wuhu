import Clocks
import ControlledTime
import Dependencies
import Foundation
import GRDB
import JSONValue
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
import SpaceFS
import Testing

private func runningFiring<R>(
  _ space: Space,
  _ body: (Box<[SessionID]>) async throws -> R,
) async throws -> R {
  let firing = SubscriptionFiring(space: space)
  let signals = space.sessions.workSignals()
  let signaled = Box<[SessionID]>([])
  return try await withThrowingTaskGroup(of: Void.self, returning: R.self) { group in
    group.addTask { await firing.run() }
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
