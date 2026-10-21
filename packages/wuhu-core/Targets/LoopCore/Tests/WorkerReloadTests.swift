import enum MainHub.SessionError
import class MainHub.SessionService
import struct MainHub.UnfulfilledError
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import class MainHub.Hub
import struct MainHub.SessionAccess
import SessionDomain
import SpaceCore
import Testing

private struct ReloadFailure: Error {}

@Suite(.timeLimit(.minutes(1))) struct WorkerReloadTests {
  @Test func unarchiveAfterRebootReplacesAnArchivedMountAndRunsQueuedWork() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "reboot", kind: .agent, createdBy: "morgan", model: .test)
      let first = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig())
      let firstService = SessionService(sessions: sessions, worker: first)
      try await firstService.archive(id)
      try await firstService.interrupt(id)
      try await firstService.resume(id)
      await firstService.shutdown()
      let replies = InferenceScript([Fix.replying("reopened")])
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { try await replies($0) }))
      let service = SessionService(sessions: sessions, worker: worker)
      do {
        try await worker.deliver(id, .wake)
        try await service.interrupt(id)
        try await service.resume(id)
        _ = try await sessions.enqueue(id, input: Fix.message("after reboot"))
        try await service.unarchive(id)
        try await until("unarchived work settles") { try await sessions.settledWork(id) && replies.count == 1 }
        #expect(try await sessions.generationState(id).generation == 0)
      } catch {
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }

  @Test func aRetiredSessionHandsOverToAKernelOnRestart() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await createRetiredSession(in: space, title: "handover", createdBy: "morgan", executorKind: "contractor:old")
      let replies = InferenceScript([Fix.replying("handed over")])
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { try await replies($0) }))
      let service = SessionService(sessions: sessions, worker: worker)
      do {
        _ = try await service.restart(id, executor: .kernel(.test), note: nil)
        _ = try await service.enqueue(item: Fix.message("new executor"), to: id)
        try await until("handover work settles") { try await sessions.settledWork(id) && replies.count == 1 }
        #expect(try await sessions.generationState(id).generation == 1)
      } catch {
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }

  enum ReloadFault: CaseIterable { case hydration, cancelled, closedAdmission, revoking, shutdown }

  @Test(arguments: [false, true], ReloadFault.allCases)
  func committedLifecycleChangesReconcileReloadFailures(restart: Bool, fault: ReloadFault) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = restart
        ? try await createRetiredSession(in: space, title: "committed", createdBy: "morgan", executorKind: "contractor:old")
        : try await sessions.createSession(group: .shared, title: "committed", kind: .agent, createdBy: "morgan", model: .test)
      if !restart { _ = try await sessions.archive(id, grace: .seconds(3600)) }
      let hydrating = Box(false)
      let release = Latch()
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in
          switch fault {
          case .hydration: throw ReloadFailure()
          case .cancelled: throw CancellationError()
          case .closedAdmission: throw UnfulfilledError()
          case .revoking: throw SessionError.archiveInProgress
          case .shutdown:
            hydrating.withLock { $0 = true }
            await release.wait(unless: { Task.isCancelled })
            try Task.checkCancellation()
          }
        }
        return access
      }())
      let worker = await SessionExecution(main: hub, loopConfig: makeConfig())
      let service = SessionService(sessions: sessions, worker: worker)
      let operation = Task {
        if restart { _ = try await service.restart(id, executor: .kernel(.test), note: nil) }
        else { try await service.unarchive(id) }
      }
      do {
        if fault == .shutdown {
          try await until("committed reload enters hydration") { hydrating.value }
          #expect(try await sessions.record(id).lifecycle == .live)
          await worker.shutdown()
        }
        try await operation.value
        let record = try await sessions.record(id)
        #expect(record.lifecycle == .live)
        #expect((record.work == .errored) == (fault == .hydration))
        #expect((record.errorMessage != nil) == (fault == .hydration))
        #expect(try await sessions.generationState(id).generation == (restart ? 1 : 0))
      } catch {
        release.release()
        operation.cancel()
        _ = await operation.result
        await service.shutdown()
        throw error
      }
      release.release()
      await service.shutdown()
    }
  }

  @Test func unarchiveRetriesAConcurrentEvictionWithoutRepeatingTheWrite() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "eviction", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.archive(id, grace: .seconds(3600))
      _ = try await sessions.enqueue(id, input: Fix.message("reopen"))
      let hydrations = Box(0)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in
          if hydrations.withLock({ $0 += 1; return $0 }) == 1 { throw UnfulfilledError() }
        }
        return access
      }())
      let replies = InferenceScript([Fix.replying("done")])
      let worker = await SessionExecution(main: hub, loopConfig: makeConfig(inference: { try await replies($0) }))
      let service = SessionService(sessions: sessions, worker: worker)
      do {
        try await service.unarchive(id)
        try await until("retry settles") { try await sessions.settledWork(id) && replies.count == 1 }
        #expect(hydrations.value == 2)
        #expect(try await sessions.generationState(id).generation == 0)
      } catch {
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }

  @Test func unreadableResumeDurablyErrorsTheSession() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "unreadable", kind: .agent, createdBy: "morgan", model: .test)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unreadable")) }
        return access
      }())
      let revoked = Box(false)
      var config = makeConfig()
      config.invalidateInference = { _ in
        #expect((try? await sessions.record(id).work) == .errored)
        revoked.withLock { $0 = true }
      }
      let worker = await SessionExecution(main: hub, loopConfig: config)
      let service = SessionService(sessions: sessions, worker: worker)
      await #expect(throws: SessionError.unreadableData(id)) { try await service.resume(id) }
      #expect(try await sessions.record(id).work == .errored)
      #expect(revoked.value)
      await service.shutdown()
    }
  }

  @Test func cancelRevocationDoesNotSuppressFutureHydrationFailures() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "retry", kind: .agent, createdBy: "morgan", model: .test)
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        access.beforeHydrate = { _ in throw ReloadFailure() }
        return access
      }())
      let worker = await SessionExecution(main: hub, loopConfig: makeConfig())
      let service = SessionService(sessions: sessions, worker: worker)
      #expect(try await worker.revoke(id, policy: .cancel))
      _ = try await service.enqueue(item: Fix.message("fails visibly"), to: id)
      #expect(try await sessions.record(id).work == .errored)
      await service.shutdown()
    }
  }
}
