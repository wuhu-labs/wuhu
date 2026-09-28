import Dependencies
import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct EvictionTests {
  @Test func `a dropped callback resolves to UnfulfilledError`() async throws {
    await #expect(throws: UnfulfilledError.self) {
      try await withCallback(of: Void.self) { _ in }
    }
  }

  @Test func `the idle sweep evicts settled sessions and the next verb rematerializes`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("first"),
        Fix.replying("second"),
      ])
      let config = makeConfig(
        inference: { try await script($0) },
        eviction: .init(idleTTL: .seconds(300), maxIdle: 32, sweepInterval: .seconds(30)),
      )

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("settled") { try await sessions.settledWork(sid) }
        // idleSince set = the loop pass fully ended; advancing earlier would
        // sweep a session that still looks in-flight.
        try await until("idle") {
          await service.registry.sessions[sid]?.idleSince != nil
        }

        // Sweep by sweep: the reaper sleeps again after each one.
        for _ in 0 ..< 11 {
          try await time.wake("the reaper", after: 30)
        }
        try await until("evicted") {
          await service.registry.sessions.isEmpty
        }

        // Write-through made eviction safe: the verb lands on a lazily
        // rehydrated session with the full transcript intact.
        _ = try await service.enqueue(item: Fix.message("two"), to: sid)
        try await until("settled again") { try await sessions.settledWork(sid) }
      }

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.count == 2)
      #expect(transcript.items.count == 4)
    }
  }

  @Test func `a callback lost to a racing terminal error surfaces retryably and the retry lands`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        { _ in
          @Dependency(\.continuousClock) var clock
          do {
            try await clock.sleep(for: .seconds(1_000_000))
          } catch {
            // The provider answers the cancel with a real 400: terminal, so
            // markErrored overwrites the interrupting callback — the
            // documented lost-callback race.
            throw InferenceError.invalidInput(status: 400, body: "boom")
          }
          throw UnexpectedCall("hanging inference elapsed")
        },
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt in flight") { script.count == 1 }

        // Without SessionService's single retry this would throw
        // UnfulfilledError; with it, the retry observes the parked session.
        try await service.interrupt(sid)

        let record = try await sessions.record(sid)
        #expect(record.work == .errored)
      }
    }
  }
}
