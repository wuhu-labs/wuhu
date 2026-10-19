import Dependencies
import class MainHub.Hub
import enum MainHub.RevocationPolicy
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

@Suite(.timeLimit(.minutes(1))) struct WorkerRevocationTests {
  @Test func aLateWakeCannotHydrateThroughMainArchiveReservation() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "reserved wake", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.replying("after rollback")])
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { try await script($0) }))
      let reservation = UUID()
      do {
        _ = try await sessions.enqueue(id, input: Fix.message("queued work"))
        try await sessions.reserveForArchive(id, token: reservation)
        await #expect(throws: ExecutionHydrationError.reservedForArchive(id)) { try await worker.deliver(id, .wake) }
        #expect(script.count == 0)
        #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.isEmpty)
        sessions.releaseArchiveReservation(id, token: reservation)
        try await worker.deliver(id, .wake)
        try await until("released reservation permits hydration") { try await sessions.settledWork(id) && script.count == 1 }
      } catch {
        sessions.releaseArchiveReservation(id, token: reservation)
        await worker.shutdown()
        throw error
      }
      await worker.shutdown()
    }
  }

  @Test func cancelRevocationFencesLateInferenceAndInFlightWakes() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "revocation", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("first"))
      let entered = Box(false), cancelled = Box(false), returned = Box(false)
      let release = Latch()
      let hydrations = Box(0)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in hydrations.withLock { $0 += 1 } }
        return access
      }())
      let worker = await SessionExecution(main: hub, loopConfig: makeConfig(inference: { _ in
        await withTaskCancellationHandler {
          entered.withLock { $0 = true }
          await release.wait()
          return Fix.reply("late old reply")
        } onCancel: {
          cancelled.withLock { $0 = true }
        }
      }))
      try await worker.deliver(id, .wake)
      try await until("inference entered") { entered.value }
      let revoke = Task {
        let result = try await worker.revoke(id, policy: .cancel)
        returned.withLock { $0 = true }
        return result
      }
      do {
        try await until("inference cancellation") { cancelled.value }
        #expect(!returned.value)
        _ = try await sessions.enqueue(id, input: Fix.message("during revoke", message: "next"))
        try await worker.deliver(id, .wake)
        #expect(hydrations.value == 1)
        #expect(!returned.value)
        release.release()
        #expect(try await revoke.value)
        #expect(hydrations.value == 1)
        let hydration = try await sessions.hydrate(id)
        #expect(hydration.transcript.kernel.assistantEntries.isEmpty)
        #expect(hydration.record.errorMessage == nil)
        #expect(hydration.record.work == .hasWork)
        #expect(hydration.undrained.count == 1)
      } catch {
        release.release()
        _ = await revoke.result
        await worker.shutdown()
        throw error
      }
      await worker.shutdown()
    }
  }

  @Test func settledRevocationRefusesActiveWorkWithoutCancellingIt() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "busy revoke", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false), cancelled = Box(false)
      let release = Latch()
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { _ in
        await withTaskCancellationHandler {
          entered.withLock { $0 = true }
          await release.wait(unless: { Task.isCancelled })
          return Fix.reply("finished normally")
        } onCancel: {
          cancelled.withLock { $0 = true }
        }
      }))
      do {
        _ = try await sessions.enqueue(id, input: Fix.message("work"))
        try await worker.deliver(id, .wake)
        try await until("busy inference entered") { entered.value }
        let revoked = try await worker.revoke(id, policy: .whenSettled)
        #expect(!revoked)
        #expect(!cancelled.value)
        release.release()
        try await until("refused revocation leaves inference alive") { try await sessions.settledWork(id) }
        #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.count == 1)
      } catch {
        release.release()
        await worker.shutdown()
        throw error
      }
      await worker.shutdown()
    }
  }

  @Test(arguments: [RevocationPolicy.whenSettled, .cancel])
  func reloadReopensAdmissionWithoutChangingTheGenerationPrefix(policy: RevocationPolicy) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "reload", kind: .agent, createdBy: "morgan", model: .test)
      let seen = Box<[Transcript]>([])
      let script = InferenceScript([
        Fix.replying("first reply"),
        { request in
          seen.withLock { $0.append(request.transcript) }
          return Fix.reply("second reply")
        },
      ])
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { try await script($0) }))
      do {
        _ = try await sessions.enqueue(id, input: Fix.message("first"))
        try await worker.deliver(id, .wake)
        try await until("first reply settles") { try await sessions.settledWork(id) }
        let prefix = try await sessions.hydrate(id).transcript.kernel.items
        try await until("completed pass can be revoked") { try await worker.revoke(id, policy: policy) }
        let input = Fix.message("second", message: "second")
        _ = try await sessions.enqueue(id, input: input)
        if case .whenSettled = policy {
          try await worker.deliver(id, .wake)
          #expect(script.count == 1)
          #expect(try await sessions.undrainedInputs(id).map(\.input) == [input])
        }
        try await worker.deliver(id, .reload)
        try await until("reloaded work settles") { try await sessions.settledWork(id) && script.count == 2 }
        let request = try #require(seen.value.first)
        #expect(Array(request.items.prefix(prefix.count)) == prefix)
        #expect(try await sessions.generationState(id).generation == 0)
      } catch {
        await worker.shutdown()
        throw error
      }
      await worker.shutdown()
    }
  }

  @Test func reloadPreservesInterruptedHoldUntilExplicitResume() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "held reload", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.markInterrupted(id)
      let script = InferenceScript([Fix.replying("resumed")])
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { try await script($0) }))
      do {
        #expect(try await worker.revoke(id, policy: .cancel))
        _ = try await sessions.enqueue(id, input: Fix.message("held work"))
        let held = try await sessions.hydrate(id).transcript.kernel
        try await worker.deliver(id, .reload)
        #expect(script.count == 0)
        #expect(try await sessions.hydrate(id).transcript.kernel == held)
        try await worker.deliver(id, .resume)
        try await until("explicit resume settles") { try await sessions.settledWork(id) && script.count == 1 }
      } catch {
        await worker.shutdown()
        throw error
      }
      await worker.shutdown()
    }
  }
}
