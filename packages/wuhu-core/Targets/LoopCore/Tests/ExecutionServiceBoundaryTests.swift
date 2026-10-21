import Clocks
import Dependencies
import Foundation
@testable import LoopCore
import MainHub
import class MainHub.Hub
import struct MainHub.SessionAccess
import class MainHub.SessionService
import struct MainHub.UnfulfilledError
import SessionDomain
import SessionTools
import SpaceCore
import Synchronization
import Testing

private struct ReplyLost: Error {}

@Suite(.timeLimit(.minutes(1))) struct ExecutionServiceBoundaryTests {
  enum ServiceUse: CaseIterable { case idle, unknown, settled }

  @Test(arguments: ServiceUse.allCases, [false, true])
  func droppingTheServiceReleasesItsHubAndCancelsSleepers(use: ServiceUse, pendingReminder: Bool) async throws {
    try await withKernelDeps { time in
      weak var releasedSpace: Space?
      weak var releasedHub: Hub?
      var service: SessionService?
      do {
        let space = try Space.inMemory()
        let hub = Hub(space: space)
        releasedSpace = space
        releasedHub = hub
        service = await SessionService(sessions: space.sessions, main: hub, loopConfig: makeConfig(inference: { _ in Fix.reply("done") }))
        switch use {
        case .idle: break
        case .unknown:
          await #expect(throws: SessionStoreError.unknownSession("missing")) {
            try await service!.wake(SessionID("missing"))
          }
        case .settled:
          let id = try await space.sessions.createSession(group: .shared, title: "used", kind: .agent, createdBy: "morgan", model: .test)
          _ = try await service!.enqueue(item: Fix.message("one turn"), to: id)
          try await until("turn settles") { try await space.sessions.settledWork(id) }
        }
      }
      try await time.asleep("registry reaper", dueIn: 30)
      if pendingReminder {
        await service!.scheduleWake(SessionID("fixture"), at: anchor.addingTimeInterval(60))
        try await time.asleep("parent reminder", dueIn: 60)
      }
      service = nil
      try await until("dropped hub releases its store") { releasedHub == nil && releasedSpace == nil }
      try await until("owner cancels all sleepers") { time.sleepCount == 0 }
      await time.advance(by: 120)
      #expect(time.sleepCount == 0)
    }
  }

  @Test func anUnknownExecutionWakeLeavesNoActivatedActor() async throws {
    try await withKernelDeps { time in
      weak var releasedSpace: Space?
      var execution: SessionExecution?
      do {
        let space = try Space.inMemory()
        releasedSpace = space
        execution = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig())
      }
      await #expect(throws: SessionStoreError.unknownSession("missing")) {
        try await execution!.deliver(SessionID("missing"), .wake)
      }
      execution = nil
      try await until("unknown execution releases its store") { releasedSpace == nil }
      try await until("unknown execution cancels its sleepers") { time.sleepCount == 0 }
    }
  }

  @Test func committedEnqueueSurvivesWakeHydrationFailure() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "enqueue", kind: .agent, createdBy: "morgan", model: .test)
      let wakes = Box(0)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in
          wakes.withLock { $0 += 1 }
          throw ReplyLost()
        }
        return access
      }())
      let service = await SessionService(sessions: sessions, main: hub, loopConfig: makeConfig())
      let input = Fix.message("once")
      #expect(try await service.enqueue(item: input, to: id) == 1)
      #expect(try await sessions.undrainedInputs(id).map(\.input) == [input])
      #expect(wakes.value == 1)
      await service.shutdown()
    }
  }

  @Test func bootWakeRetriesHydrationWithoutPoisoningPersistedWork() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "boot", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("boot"))
      let wakes = Box(0)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in
          let count = wakes.withLock { $0 += 1; return $0 }
          if count <= 2 { throw UnfulfilledError() }
        }
        return access
      }())
      let service = await SessionService(sessions: sessions, main: hub, loopConfig: makeConfig(inference: { _ in Fix.reply("done") }))
      try await runService(service) { _ in
        try await time.asleep("boot wake retry", dueIn: 1)
        await time.advance(by: 1)
        try await until("boot settles") { try await sessions.settledWork(id) }
        #expect(wakes.value == 3)
        #expect(try await sessions.record(id).work != .errored)
      }
    }
  }

  // Main boots before its worker has announced, or between two of them: the
  // session waits for one, and is never failed for it.
  @Test func bootWakeWaitsForAWorkerInsteadOfFailingTheSession() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "boot", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("boot"))
      let execution = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { _ in Fix.reply("done") }))
      let worker = Unannounced(execution, absentFor: 5)
      let service = SessionService(sessions: sessions, worker: worker)
      try await runService(service) { _ in
        for _ in 1 ... 5 {
          try await time.asleep("waiting for a worker", dueIn: 1)
          await time.advance(by: 1)
        }
        try await until("boot settles") { try await sessions.settledWork(id) }
        #expect(try await sessions.record(id).work != .errored)
        #expect(worker.refused.withLock { $0 } == 5)
      }
    }
  }

  @Test func parentRemindersReplaceDeadlinesCancelAndJoinAtShutdown() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "reminder", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.replying("reminded")])
      let service = await SessionService(sessions: sessions, main: Hub(space: space), loopConfig: makeConfig(inference: { try await script($0) }))
      _ = try await sessions.enqueue(id, input: Fix.message("pending"))
      await service.scheduleWake(id, at: anchor.addingTimeInterval(10))
      try await time.asleep("first deadline", dueIn: 10)
      await service.scheduleWake(id, at: anchor.addingTimeInterval(20))
      try await time.asleep("replacement deadline", dueIn: 20)
      await time.advance(by: 10)
      try await holds("replaced deadline never fires") { script.count == 0 }
      await time.advance(by: 10)
      try await until("replacement fires once") { try await sessions.settledWork(id) && script.count == 1 }
      _ = try await sessions.enqueue(id, input: Fix.message("next", message: "next"))
      await service.scheduleWake(id, at: anchor.addingTimeInterval(30))
      try await time.asleep("cancelled deadline", dueIn: 10)
      await service.scheduleWake(id, at: nil)
      await time.advance(by: 10)
      try await holds("cancelled deadline never fires") { script.count == 1 }
      await service.scheduleWake(id, at: anchor.addingTimeInterval(40))
      try await time.asleep("shutdown deadline", dueIn: 10)
      await service.shutdown()
      await time.advance(by: 10)
      #expect(script.count == 1)
      #expect(try await sessions.undrainedInputs(id).count == 1)
    }
  }

  @Test(arguments: [false, true])
  func parentReminderWakeFailuresRetryAndBecomeVisibleAfterExhaustion(exhausted: Bool) async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "reminder", kind: .task, createdBy: "morgan", model: .test)
      let wakes = Box(0)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in
          let attempt = wakes.withLock { $0 += 1; return $0 }
          if exhausted || attempt < 4 { throw ReplyLost() }
        }
        return access
      }())
      let service = await SessionService(sessions: sessions, main: hub, loopConfig: makeConfig())
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

// A worker main cannot reach yet: the first verbs find no worker announced.
private final class Unannounced: Worker, Sendable {
  let execution: SessionExecution
  let absentFor: Int
  let refused = Mutex(0)

  init(_ execution: SessionExecution, absentFor: Int) {
    self.execution = execution
    self.absentFor = absentFor
  }

  private func reach() throws {
    let absent = refused.withLock { count in
      guard count < absentFor else { return false }
      count += 1
      return true
    }
    if absent { throw NoWorkerError() }
  }

  func deliver(_ session: SessionID, _ input: WorkerInput) async throws {
    try reach()
    try await execution.deliver(session, input)
  }

  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool { try await execution.revoke(session, policy: policy) }
  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { try await execution.fire(invocation) }
  func activity() async -> WorkerActivity { await execution.activity() }
  func runningWork(_ session: SessionID) async throws -> [String] { try await execution.runningWork(session) }
  func shutdown() async { await execution.shutdown() }
}
