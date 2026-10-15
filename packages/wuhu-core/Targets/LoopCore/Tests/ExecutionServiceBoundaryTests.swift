import Clocks
import Dependencies
import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

private struct ReplyLost: Error {}

private struct FaultingExecution: SessionExecutionClient {
  let base: SessionExecution
  let wakeCall: @Sendable (SessionID) async throws -> Void
  let enqueueCall: @Sendable (QueueInput, SessionID) async throws -> Int
  func wake(_ id: SessionID) async throws { try await wakeCall(id) }
  func enqueue(_ item: QueueInput, to id: SessionID) async throws -> Int { try await enqueueCall(item, id) }
  func interrupt(_ id: SessionID) async throws { try await base.interrupt(id) }
  func resume(_ id: SessionID) async throws { try await base.resume(id) }
  func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool { try await base.prepareArchive(id, reservation: reservation) }
  func releaseArchive(_ id: SessionID, reservation: UUID) async throws { try await base.releaseArchive(id, reservation: reservation) }
  func archive(_ id: SessionID, reservation: UUID) async throws { try await base.archive(id, reservation: reservation) }
  func unarchive(_ id: SessionID) async throws { try await base.unarchive(id) }
  func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart { try await base.restart(id, executor: executor, note: note, modelRoute: modelRoute) }
  func discard(_ id: SessionID) async { await base.discard(id) }
  func drain() async { await base.drain() }
  func shutdown() async { await base.shutdown() }
}

@Suite(.timeLimit(.minutes(1))) struct ExecutionServiceBoundaryTests {
  @Test func committedEnqueueNeverRoundTripsThroughWorkerOrThrowsLostWakeReply() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "enqueue", kind: .agent, createdBy: "morgan", model: .test)
      let enqueues = Box(0), wakes = Box(0)
      let base = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig())
      let execution = FaultingExecution(base: base, wakeCall: { _ in
        wakes.withLock { $0 += 1 }
        throw ReplyLost()
      }, enqueueCall: { input, id in
        enqueues.withLock { $0 += 1 }
        _ = try await sessions.enqueue(id, input: input)
        throw ReplyLost()
      })
      let service = SessionService(sessions: sessions, execution: execution, archiveGrace: .seconds(60))
      let input = Fix.message("once")
      let position = try await service.enqueue(item: input, to: id)
      #expect(position == 1)
      #expect(try await sessions.undrainedInputs(id).map(\.input) == [input])
      #expect(enqueues.value == 0)
      #expect(wakes.value == 1)
      await service.shutdown()
    }
  }

  @Test func bootWakeRetriesRetiredStartupWithoutPoisoningPersistedWork() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "boot", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("boot"))
      let wakes = Box(0)
      let base = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig(inference: { _ in Fix.reply("done") }))
      let execution = FaultingExecution(base: base, wakeCall: { id in
        let count = wakes.withLock { $0 += 1; return $0 }
        if count <= 2 { throw SessionExecutionRetired() }
        try await base.wake(id)
      }, enqueueCall: { _, _ in throw UnexpectedCall("worker enqueue") })
      let service = SessionService(sessions: sessions, execution: execution, archiveGrace: .seconds(60))
      try await runService(service) { _ in
        try await time.asleep("boot wake retry", dueIn: 1)
        await time.advance(by: 1)
        try await until("boot settles") { try await sessions.settledWork(id) }
        #expect(wakes.value == 3)
        #expect(try await sessions.record(id).work != .errored)
      }
    }
  }

  @Test func aDelayedReminderTaskKeepsTheOriginalDeadline() async throws {
    let clock = ReminderAdmissionClock()
    try await withDependencies {
      $0.continuousClock = AnyClock(clock)
      $0.date = DateGenerator { anchor.addingTimeInterval(TestClock<Duration>.Instant().duration(to: clock.now).timeInterval) }
    } operation: {
      let sessions = try Space.inMemory().sessions
      let wakes = Box<[Date]>([])
      let base = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig())
      let execution = FaultingExecution(base: base, wakeCall: { _ in
        @Dependency(\.date) var date
        wakes.withLock { $0.append(date.now) }
      }, enqueueCall: { _, _ in throw UnexpectedCall("enqueue") })
      let reminders = SessionReminders(sessions: sessions, execution: execution)
      await reminders.scheduleBeforeTaskAdmission(.init("fixture"), at: anchor.addingTimeInterval(60), clock: clock)
      do {
        try await until("delayed reminder starts sleeping") { clock.sleepStarted.value }
        await clock.base.advance(by: .seconds(29))
        #expect(wakes.value.isEmpty)
        await clock.base.advance(by: .seconds(1.000001))
        try await until("original reminder deadline fires") { wakes.value.count == 1 }
        #expect(abs(try #require(wakes.value.first).timeIntervalSince(anchor) - 60) < 0.001)
      } catch {
        await reminders.shutdown()
        await base.shutdown()
        throw error
      }
      await reminders.shutdown()
      await base.shutdown()
    }
  }

  @Test func parentRemindersReplaceDeadlinesCancelAndJoinAtShutdown() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let id = SessionID("fixture")
      let wakes = Box(0)
      let base = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig())
      let execution = FaultingExecution(base: base, wakeCall: { _ in wakes.withLock { $0 += 1 } }, enqueueCall: { _, _ in throw UnexpectedCall("enqueue") })
      let service = SessionService(sessions: sessions, execution: execution, archiveGrace: .seconds(60))
      await service.scheduleWake(id, at: anchor.addingTimeInterval(10))
      try await time.asleep("first deadline", dueIn: 10)
      await service.scheduleWake(id, at: anchor.addingTimeInterval(20))
      try await time.asleep("replacement deadline", dueIn: 20)
      await time.advance(by: 10)
      try await holds("replaced deadline never fires") { wakes.value == 0 }
      await time.advance(by: 10)
      try await until("replacement fires once") { wakes.value == 1 }
      await service.scheduleWake(id, at: anchor.addingTimeInterval(30))
      try await time.asleep("cancelled deadline", dueIn: 10)
      await service.scheduleWake(id, at: nil)
      await time.advance(by: 10)
      try await holds("cancelled deadline never fires") { wakes.value == 1 }
      await service.scheduleWake(id, at: anchor.addingTimeInterval(40))
      try await time.asleep("shutdown deadline", dueIn: 10)
      await service.shutdown()
      await time.advance(by: 10)
      try await holds("shutdown joins pending reminders") { wakes.value == 1 }
    }
  }

  @Test(arguments: [false, true])
  func parentReminderWakeFailuresRetryAndBecomeVisibleAfterExhaustion(exhausted: Bool) async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "reminder", kind: .task, createdBy: "morgan", model: .test)
      let wakes = Box(0)
      let base = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig())
      let execution = FaultingExecution(base: base, wakeCall: { _ in
        let attempt = wakes.withLock { $0 += 1; return $0 }
        if exhausted || attempt < 4 { throw ReplyLost() }
      }, enqueueCall: { _, _ in throw UnexpectedCall("enqueue") })
      let service = SessionService(sessions: sessions, execution: execution, archiveGrace: .seconds(60))
      await service.scheduleWake(id, at: anchor.addingTimeInterval(10))
      try await time.asleep("reminder", dueIn: 10)
      await time.advance(by: 10)
      for delay in [1, 2, 4] {
        try await time.asleep("reminder wake retry", dueIn: Double(delay))
        await time.advance(by: Double(delay))
      }
      try await until("four attempts complete") { wakes.value == 4 }
      if exhausted {
        try await until("failure persisted") { try await sessions.record(id).work == .errored }
      } else {
        #expect(try await sessions.record(id).work == .noWork)
      }
      await service.shutdown()
    }
  }
}

private struct ReminderAdmissionClock: Clock {
  let base = TestClock<Duration>()
  let admissionDelay = Box<Duration>(.zero)
  let sleepStarted = Box(false)
  var now: TestClock<Duration>.Instant { base.now.advanced(by: admissionDelay.value) }
  var minimumResolution: Duration { base.minimumResolution }

  func sleep(until deadline: TestClock<Duration>.Instant, tolerance: Duration?) async throws {
    let deadline = deadline.advanced(by: .zero - admissionDelay.value)
    sleepStarted.withLock { $0 = true }
    try await base.sleep(until: deadline, tolerance: tolerance)
  }
}

private extension SessionReminders {
  func scheduleBeforeTaskAdmission(_ id: SessionID, at due: Date, clock: ReminderAdmissionClock) {
    schedule(id, at: due)
    // This actor turn holds the spawned reminder task until the clock has moved.
    clock.admissionDelay.withLock { $0 = .seconds(30) }
  }
}
