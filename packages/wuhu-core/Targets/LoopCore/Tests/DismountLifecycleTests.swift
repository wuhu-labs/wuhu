import class MainHub.Hub
import struct MainHub.SessionAccess
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct DismountLifecycleTests {
  @Test func cancelledLooperCannotEnterCompactRequestAfterDismount() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "teardown", kind: .agent, createdBy: "morgan", model: .test)
      let passes = Box(0), pendingReads = Box(0)
      let cancelled = Box(false)
      let oldRelease = Latch()
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.afterPendingCommand = { _ in pendingReads.withLock { $0 += 1 } }
        return access
      }())
      var config = makeConfig(eviction: .init(idleTTL: .seconds(1), maxIdle: 0, sweepInterval: .seconds(1)))
      config.budget = { _ in
        passes.withLock { $0 += 1 }
        await withTaskCancellationHandler {
          await oldRelease.wait()
        } onCancel: {
          cancelled.withLock { $0 = true }
        }
        return .init(maxInput: 1_001_000, maxOutput: 1000)
      }
      let worker = await SessionExecution(main: hub, loopConfig: config)
      do {
        try await worker.deliver(id, .wake)
        try await until("old loop paused before compact polling") { passes.value == 1 }
        let shutdown = Task { await worker.shutdown() }
        try await until("shutdown cancels old loop") { cancelled.value }
        oldRelease.release()
        await shutdown.value
        #expect(pendingReads.value == 0)
        #expect(try await sessions.pendingCommand(id) == nil)
        #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.isEmpty)
      } catch {
        oldRelease.release()
        await worker.shutdown()
        throw error
      }
    }
  }
}
