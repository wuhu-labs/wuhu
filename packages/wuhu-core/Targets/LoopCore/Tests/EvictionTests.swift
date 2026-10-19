import Dependencies
import Foundation
@testable import LoopCore
import class MainHub.Hub
import struct MainHub.SessionAccess
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
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("first"),
        Fix.replying("second"),
      ])
      let invalidated = Box<[SessionID]>([])
      var config = makeConfig(
        inference: { try await script($0) },
        eviction: .init(idleTTL: .seconds(300), maxIdle: 32, sweepInterval: .seconds(30)),
      )

      config.invalidateInference = { id in invalidated.withLock { $0.append(id) } }
      let hydrations = Box(0)
      let service = await SessionService(sessions: sessions, main: Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in hydrations.withLock { $0 += 1 } }
        return access
      }()), loopConfig: config)
      try await runService(service) { service in
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("settled") { try await sessions.settledWork(sid) }
        try await until("idle eviction invalidates inference") {
          if !invalidated.value.isEmpty { return true }
          try await time.wake("idle sweep", after: 30)
          return !invalidated.value.isEmpty
        }
        try await time.asleep("next idle sweep", dueIn: 30)
        #expect(invalidated.value == [sid])
        #expect(hydrations.value == 1)
        _ = try await service.enqueue(item: Fix.message("two"), to: sid)
        try await until("settled again") { try await sessions.settledWork(sid) && script.count == 2 }
        #expect(hydrations.value == 2)
      }

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.count == 2)
      #expect(transcript.items.count == 4)
    }
  }

  @Test func `a callback lost to a racing terminal error surfaces retryably and the retry lands`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
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

      try await runService(space, config) { service in
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
