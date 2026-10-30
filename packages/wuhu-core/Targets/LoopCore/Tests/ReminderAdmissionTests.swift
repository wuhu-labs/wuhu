import Clocks
import ControlledTime
import Dependencies
import class MainHub.Hub
import class MainHub.SessionService
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LoopCore
import SessionDomain
import SpaceCore
import Testing

private struct ReminderAdmissionClock: NonsendingClock {
  let base = VirtualClock()
  let admissionDelay = Box<Duration>(.zero)
  let sleepStarted = Box(false)

  var now: VirtualClock.Instant {
    let delay = admissionDelay.withLock { delay in
      let previous = delay
      delay = .seconds(30)
      return previous
    }
    return base.now.advanced(by: delay)
  }

  var minimumResolution: Duration { base.minimumResolution }
  var currentDate: Date {
    let elapsed = VirtualClock.at(.zero).duration(to: base.now) + admissionDelay.value
    return anchor.addingTimeInterval(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
  }

  func sleep(until deadline: VirtualClock.Instant, tolerance: Duration?) async throws {
    let translated = deadline.advanced(by: .zero - admissionDelay.value)
    sleepStarted.withLock { $0 = true }
    try await base.sleep(until: translated, tolerance: tolerance)
  }
}

@Suite(.timeLimit(.minutes(1))) struct ReminderAdmissionTests {
  @Test func aDelayedReminderTaskKeepsTheOriginalDeadline() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "delayed reminder", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("pending"))
      let clock = ReminderAdmissionClock()
      let wakes = Box<[Date]>([])
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { _ in
        wakes.withLock { $0.append(clock.currentDate) }
        return Fix.reply("reminded")
      }))
      try await withDependencies {
        $0.continuousClock = AnyClock(clock)
        $0.date = DateGenerator { clock.currentDate }
      } operation: {
        let service = SessionService(sessions: sessions, worker: worker)
        do {
          await service.scheduleWake(id, at: anchor.addingTimeInterval(60))
          try await until("delayed reminder task begins sleeping") { clock.sleepStarted.value }
          #expect(clock.admissionDelay.value == .seconds(30))
          await clock.base.advance(by: .seconds(29))
          #expect(wakes.value.isEmpty)
          await clock.base.advance(by: .seconds(1.000001))
          try await until("original deadline fires") { wakes.value.count == 1 }
          #expect(abs(try #require(wakes.value.first).timeIntervalSince(anchor) - 60) < 0.001)
          try await until("reminded work settles") { try await sessions.settledWork(id) }
        } catch {
          await service.shutdown()
          throw error
        }
        await service.shutdown()
      }
    }
  }
}
