import Clocks
import ControlledTime
import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import JSONValue
import Logging
@testable import MainHub
import class MainHub.Hub
import SessionDomain
@testable import SessionTools
@testable import SpaceServer
@_spi(SessionObservation) @testable import SpaceCore
import SpaceFS
import Testing

private func runningFiring<R>(
  _ space: Space,
  log: Logger? = nil,
  configure: (inout SubscriptionFiring) -> Void = { _ in },
  _ body: () async throws -> R,
) async throws -> R {
  let worker = await withDependencies {
    $0.installTimeControl(anchor: anchor)
  } operation: {
    await firingWorker(Hub(space: space))
  }
  var firing = SubscriptionFiring(space: space) { worker.observe($0, $1, $2) }
  if let log { firing.log = log }
  configure(&firing)
  let service = firing
  return try await withThrowingTaskGroup(of: Void.self, returning: R.self) { group in
    group.addTask { await whenCancelled { await worker.shutdown() } }
    group.addTask { await service.run() }
    defer { group.cancelAll() }
    return try await body()
  }
}

private func tablePath(_ raw: String) throws -> SpacePath {
  try SpacePath(validating: raw)
}

private func tracingSpace(_ executed: @escaping @Sendable (String) -> Void) throws -> Space {
  var configuration = Space.makeConfiguration(journalMode: .default)
  configuration.prepareDatabase { db in
    db.trace { event in
      if case let .statement(statement) = event { executed(statement.sql) }
    }
  }
  return try Space.inMemory(configuration: configuration, trace: executed)
}

private func observationNotifications(_ space: Space, session: SessionID) async throws -> [SystemNotification] {
  try await space.sessions.undrainedInputs(session).compactMap { entry in
    guard case let .notification(notification) = entry.input, notification.kind == .spaceObservation else {
      return nil
    }
    return notification
  }
}

@Suite(.deterministicDependencies) struct SubscriptionTests {
  @Test func startOverKeepsLiveObservationCronOneShotAndRequestDeadline() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let child = try await space.sessions.createSession(group: .shared, title: "child", kind: .task, parent: session, createdBy: session.rawValue, executor: try await space.sessions.record(session).executor)
      let watched = try tablePath("/restart.table")
      _ = try await space.createTable(watched, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      // Arming is a step of the session's cell. Both are held, so their cells leave the queues for this test to read.
      try await space.sessions.markInterrupted(session)
      try await space.sessions.markInterrupted(child)
      _ = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      guard case let .observe(observation) = try await world.run("observe", .object(["sql": "SELECT n FROM \"/restart.table\"", "throttle_seconds": 1])) else { throw Mismatch("observe failed") }
      _ = try await world.run("timer", .object(["message": "cron survives", "cron": "* * * * *"]))
      _ = try await world.run("timer", .object(["message": "once survives", "in_seconds": 120]))
      _ = try await space.sessions.openRequest(on: child, from: .session(session), messageID: .init("restart-duty"), text: "still owed")
      _ = try await space.sessions.drainQueue(child)
      try await space.sessions.put(session, input: .message(.init(id: UUID(), messageID: .init("queued"), conversationID: .init("ch1"), sender: .init(id: "morgan", timeZone: TimeZone(identifier: "UTC")!), timestamp: anchor, content: .init(text: "queued before Start over"))))
      let before = try await space.sessions.armedSubscriptions(session)
      try await runningFiring(space) {
        _ = try await space.sessions.restart(session, note: "catch up")
        // Held, so its cell leaves the queue for this test to read.
        try await space.sessions.markInterrupted(session)
        #expect(try await space.sessions.armedSubscriptions(session) == before)
        let hydration = try await space.sessions.hydrate(session)
        #expect(try await space.sessions.undrainedInputs(session).count == 1)
        #expect(hydration.record.work == .hasWork)
        _ = try await space.sessions.drainQueue(session)
        _ = try await space.mutateRows(watched, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await until("the existing observation still fires") { try await observationNotifications(space, session: session).count == 1 }
        #expect(try await observationNotifications(space, session: session).first?.subscriptionID == observation.subscriptionID)
        await time.advance(by: 121)
        try await untilAdvancing("cron and one-shot still fire", time) {
          let entries = try await space.sessions.undrainedInputs(session)
          let notifications = entries.compactMap { entry -> SystemNotification? in
            guard case let .notification(notification) = entry.input else { return nil }
            return notification
          }
          return notifications.contains { $0.content.text == "cron survives" }
            && notifications.contains { $0.content.text == "once survives" }
        }
        #expect(try await space.sessions.armedSubscriptions(session).count == 1)
        #expect(try await space.sessions.openRequests(child).map(\.id) == [.init("restart-duty")])
        _ = try await space.sessions.drainQueue(session)
        await time.advance(by: 60)
        try await untilAdvancing("cron fires again", time) {
          try await space.sessions.undrainedInputs(session).filter {
            guard case let .notification(notification) = $0.input else { return false }
            return notification.content.text == "cron survives"
          }.count == 1
        }
      }
    }
  }

  @Test func aOneShotTimerIsAnInputThatComesDueOnce() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      // Held, so its cell arms the timer and leaves the queue for this test to drain.
      try await space.sessions.markInterrupted(session)
      let worker = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      guard case let .timer(armed) = try await world.run(
        "timer", .object(["message": "check the build", "in_seconds": 60]),
      ) else { throw Mismatch("timer arming failed") }
      #expect(try await space.sessions.armedSubscriptions().isEmpty, "a plain timer is no slot")

      await time.advance(by: 59)
      #expect(try await space.sessions.drainQueue(session).items.isEmpty, "not due yet")
      await time.advance(by: 2)
      let drained = try await space.sessions.drainQueue(session).items
      guard case let .notification(fired)? = drained.first, drained.count == 1 else { throw Mismatch("expected the timer, got \(drained)") }
      #expect(fired.kind == .timer)
      #expect(fired.subscriptionID == armed.subscriptionID)
      #expect(fired.endsSubscription)
      #expect(fired.content.text == "check the build")
      await time.advance(by: 3600)
      #expect(try await space.sessions.drainQueue(session).items.isEmpty, "a one-shot puts nothing next")
      await worker.shutdown()
    }
  }

  @Test func aCronTimerPutsItsNextFiringWhenDrainedSkippingWhatItSlept() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      // Held, so its cell arms the timer and leaves the queue for this test to drain.
      try await space.sessions.markInterrupted(session)
      let worker = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      guard case .timer = try await world.run("timer", .object(["message": "tick", "cron": "*/5 * * * *"])) else { throw Mismatch("cron arming failed") }

      await time.advance(by: 5 * 60 + 1)
      let first = try await space.sessions.drainQueue(session).items
      guard case let .notification(tick)? = first.first, first.count == 1 else { throw Mismatch("expected one tick") }
      #expect(!tick.endsSubscription)

      await time.advance(by: 3 * 5 * 60)
      #expect(try await space.sessions.drainQueue(session).items.count == 1, "missed firings are one input, not three")
      await time.advance(by: 4 * 60)
      #expect(try await space.sessions.drainQueue(session).items.isEmpty, "the next firing is after the drain")
      await time.advance(by: 60)
      #expect(try await space.sessions.drainQueue(session).items.count == 1)
      await worker.shutdown()
    }
  }

  @Test func observationWriteFailureRetriesWithoutRetiringTheSlot() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      try await space.sessions.armSubscription(session, slot: .init(id: .init("obs.retry"), kind: .observe(sql: "SELECT 1", throttleSeconds: 1)))
      try await space.sessions.markInterrupted(session)
      let remaining = Box(1)
      try await installTransientQueueFailure(space, remaining: remaining)
      let messages = Box<[String]>([])
      let log = Logger(label: "test.observation-retry") { _ in FiringLogHandler(errors: messages) }
      try await runningFiring(space, log: log) {
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
      try await space.sessions.markInterrupted(session)
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
      }) {
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

  @Test func cancelRetiresSubscriptionsAndTypesWhatItCannot() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      // Held, so its cell arms and cancels and leaves the queue for this test to drain.
      try await space.sessions.markInterrupted(session)
      let worker = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)

      guard case let .timer(timer) = try await world.run(
        "timer", .object(["message": "x", "in_seconds": 600]),
      ) else { throw Mismatch("timer arming failed") }
      guard case let .observe(observation) = try await world.run(
        "observe", .object(["sql": "SELECT 1"]),
      ) else { throw Mismatch("observe arming failed") }

      let unknown = try await world.run("cancel", .object(["id": "timer.nope"]))
      #expect(try failure(unknown).code == "notFound")

      let bare = try await world.run("cancel", .object(["id": "0a1b2c3d"]))
      #expect(try failure(bare).code == "invalidArgument")
      #expect(try failureMessage(bare).contains("script.0a1b2c3d"))
      #expect(try failure(try await world.run("cancel", .object(["id": "exec.x"]))).code == "notFound")

      // Another session's subscription reads as unknown.
      let other = try await makeSession(space, name: "other")
      var foreign = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: other)
      let stranger = try await foreign.run("cancel", .object(["id": .string(timer.subscriptionID.rawValue)]))
      #expect(try failure(stranger).code == "notFound")

      guard case .cancelTimer = try await world.run(
        "cancel", .object(["id": .string(timer.subscriptionID.rawValue)]),
      ) else { throw Mismatch("cancel of the timer failed") }
      guard case .cancelObservation = try await world.run(
        "cancel", .object(["id": .string(observation.subscriptionID.rawValue)]),
      ) else { throw Mismatch("cancel of the observation failed") }
      #expect(try await space.sessions.armedSubscriptions().isEmpty)

      // An ended subscription reads as one that never was, for its owner as
      // for another session.
      for id in [timer.subscriptionID, observation.subscriptionID] {
        let again = try failure(try await world.run("cancel", .object(["id": .string(id.rawValue)])))
        #expect(again.code == "notFound")
        #expect(again.message == "\(id.rawValue) is not armed: it already ended, or you never had it")
      }
      #expect(try failure(try await foreign.run("cancel", .object(["id": .string(timer.subscriptionID.rawValue)]))).code == "notFound")

      // Still in the transcript but no longer armed: a fired one-shot timer,
      // or a cancel retried after it committed.
      var stale = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      _ = try await stale.run("timer", .object(["message": "y", "in_seconds": 600]), id: "tc-t2")
      await time.advance(by: 601)
      _ = try await space.sessions.drainQueue(session)
      let ended = try await stale.run(
        "cancel", .object(["id": .string(SubscriptionID.timer(.init("tc-t2")).rawValue)]),
      )
      #expect(try failure(ended).code == "notFound")
      await worker.shutdown()
    }
  }

  @Test func rearmingByTheSameToolCallIsIdempotent() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let worker = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)

      let first = try await world.run("timer", .object(["message": "x", "in_seconds": 60]), id: "tc-timer")
      let retried = try await world.retry("timer", .object(["message": "x", "in_seconds": 60]), id: "tc-timer")
      guard case let .timer(a) = first, case let .timer(b) = retried else {
        throw Mismatch("timer arming failed")
      }
      #expect(a.subscriptionID == b.subscriptionID)
      let pending = try await space.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM session_queue WHERE topic = ?", arguments: [a.subscriptionID.rawValue])
      }
      #expect(pending == 1, "the retry puts nothing more")
      await worker.shutdown()
    }
  }

  @Test func aSubscriptionIsNamedAfterItsHandlerUnlessNamed() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let worker = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: try await makeSession(space))
      _ = try await world.run("timer", .object(["message": "x", "in_seconds": 60, "handler": "/h/nightly.js"]), id: "tc-default")
      _ = try await world.run("timer", .object(["message": "x", "in_seconds": 60, "handler": "/h/nightly.js", "name": "evening"]), id: "tc-named")
      _ = try await world.run("observe", .object(["sql": "SELECT 1", "handler": "/h/nightly.js", "name": "rows"]), id: "tc-observed")
      let names = try await space.sessions.armedSubscriptions().compactMap(\.name).sorted()
      #expect(names == ["evening", "nightly", "rows"])
      let empty = try await world.run("timer", .object(["message": "x", "in_seconds": 60, "name": ""]), id: "tc-empty")
      #expect(try failure(empty).code == "invalidArgument")
      await worker.shutdown()
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
      try await space.sessions.markInterrupted(session)
      try await runningFiring(space) {
        await time.advance(by: 2)
        try await untilAdvancing("the error notification lands", time) {
          try await space.sessions.undrainedInputs(session).count == 1
        }
        let undrained = try await space.sessions.undrainedInputs(session)
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
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: try await makeSession(space))
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
      try await space.sessions.markInterrupted(session)
      _ = await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      let sql = "SELECT n FROM \"/watched.table\" ORDER BY n"
      guard case let .observe(armed) = try await world.run(
        "observe",
        .object(["sql": .string(sql), "throttle_seconds": 10]),
      ) else { throw Mismatch("observe arming failed") }

      func ran() -> (query: Int, registry: Int) {
        let statements = executed.value
        return (
          statements.filter { $0 == sql }.count,
          statements.filter { $0.hasPrefix("SELECT") && $0.contains("FROM \"subscription_slots\"") }.count,
        )
      }

      // The change lands while nothing is watching: a recovered observation
      // compares the snapshot against its persisted marker, not against silence.
      _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(1)])], in: .shared, acting: .shared)
      try await runningFiring(space) {
        try await until("the recovered observation notifies") {
          try await space.sessions.undrainedInputs(session).count == 1
        }
        let recovered = try #require(await observationNotifications(space, session: session).first)
        #expect(recovered.subscriptionID == armed.subscriptionID)
        #expect(!recovered.endsSubscription)
        #expect(recovered.content.text.contains(sql))

        await time.advance(by: 300)
        var idle = ran()
        try await until("the throttle's wake has run") {
          try await ContinuousClock().sleep(for: .milliseconds(20))
          defer { idle = ran() }
          return ran() == idle
        }
        try await holds("an idle observation runs no statements") { ran() == idle }

        _ = try await space.mutateRows(unrelated, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await holds("a write to another table wakes nothing") { ran() == idle }

        _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(2)])], in: .shared, acting: .shared)
        try await until("a write to the watched table replaces what the model has not seen") {
          try await observationNotifications(space, session: session).map(\.content.text) == [recovered.content.text.replacingOccurrences(of: "[[1]]", with: "[[2]]")]
        }
        #expect(ran().query > idle.query)
        #expect(try await space.sessions.drainQueue(session).items.count == 1)

        _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(3)])], in: .shared, acting: .shared)
        _ = try await space.mutateRows(watched, [.update(id: rowID, [.integer(4)])], in: .shared, acting: .shared)
        func pending() async throws -> [String] {
          try await space.writer.read {
            try String.fetchAll($0, sql: "SELECT payload FROM session_queue WHERE session_id = ? AND due_at IS NOT NULL", arguments: [session.rawValue])
          }
        }
        try await until("the latest change waits out the throttle window") { try await pending().first?.contains("[[4]]") == true }
        #expect(try await pending().count == 1)
        #expect(try await pending().first?.contains("[[3]]") == false, "the state it passed through is not news")
        #expect(try await observationNotifications(space, session: session).isEmpty, "inside the throttle window it is not due")
        await time.advance(by: 11)
        #expect(try await observationNotifications(space, session: session).count == 1)
      }
    }
  }

  @Test func aParentHearsOfAChildOnlyWhenItErrors() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let parent = try await makeSession(space)
      try await space.sessions.markInterrupted(parent)
      let child = try await space.sessions.createSession(
        group: .shared, title: "worker", kind: .task, parent: parent, createdBy: parent.rawValue,
        executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
      )
      #expect(try await space.sessions.armedSubscriptions(parent).isEmpty, "the watch is not the parent's to list")
      try await runningFiring(space) {
        try await space.sessions.markInterrupted(child)
        try await holds("an interrupted child is not news") { try await observationNotifications(space, session: parent).isEmpty }
        try await space.sessions.rows { try $0.markErrored(child, message: "boom") }
        try await until("the parent hears of it") { try await observationNotifications(space, session: parent).count == 1 }
        let told = try #require(await observationNotifications(space, session: parent).first)
        #expect(told.subscriptionID == SubscriptionSlot.childrenID)
        #expect(told.content.text.contains("boom") && told.content.text.contains("worker"))
        try await space.sessions.rows { try $0.markResumed(child) }
        try await holds("its recovery is not news") { try await observationNotifications(space, session: parent).map(\.id) == [told.id] }
        try await space.sessions.rows { try $0.markErrored(child, message: "again") }
        try await until("the parent hears of the next error") { try await observationNotifications(space, session: parent).first?.content.text.contains("again") == true }
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
  try await installTransientWriteFailure(space, remaining: remaining, table: "wuwei_mail", message: "injected transient queue write failure")
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
