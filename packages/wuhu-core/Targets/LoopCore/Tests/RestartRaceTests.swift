import class MainHub.Hub
import struct MainHub.SessionAccess
import class MainHub.SessionService
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct RestartRaceTests {
  enum ActivePass: CaseIterable { case inference, compaction, hardCompaction, committedTail }

  @Test(arguments: ActivePass.allCases, [false, true])
  func restartRefusesAPassWithWorkLeftAndJoinsOneInItsCommittedTail(pass: ActivePass, interrupted: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "active restart", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false), cancelled = Box(false), committed = Box(false)
      let release = Latch()
      var access = SessionAccess()
      // Only the revoke reads the pending command while the tail is held: the
      // pass is in its tail when the restart decides to join it.
      access.afterPendingCommand = { _ in if pass == .committedTail, entered.value { release.release() } }
      let hold: @Sendable () async -> Void = {
        await withTaskCancellationHandler {
          entered.withLock { $0 = true }
          await release.wait(unless: { Task.isCancelled })
        } onCancel: { cancelled.withLock { $0 = true } }
      }
      let worker = await SessionExecution(main: Hub(space: space, sessionAccess: access), loopConfig: makeConfig(inference: { request in
        if pass == .compaction || pass == .hardCompaction { #expect(request.mode == .forcedCompact) }
        var reply = Fix.reply("original operation finished")
        if pass == .committedTail { reply.committed = { _, _ in await hold() } } else {
          await hold()
          reply.committed = { _, _ in committed.withLock { $0 = true } }
        }
        return reply
      }, budget: .init(maxInput: 1100, maxOutput: 100)))
      let service = SessionService(sessions: sessions, worker: worker)
      do {
        if pass == .compaction { try await sessions.requestCommand(id, .compact(instructions: nil)) }
        else if pass == .hardCompaction {
          let reply = Fix.reply("settled full transcript", tokens: 950)
          try await sessions.appendAssistant(id, attemptID: UUID(), message: reply.message, metadata: reply.metadata)
        } else { _ = try await sessions.enqueue(id, input: Fix.message("work")) }
        try await service.wake(id)
        try await until("active pass entered") { entered.value }
        if interrupted { try await sessions.markInterrupted(id) }
        if pass == .committedTail {
          _ = try await service.restart(id, executor: nil, note: "fresh")
        } else {
          let before = try await sessions.hydrate(id)
          await #expect(throws: SessionStoreError.busyForRestart(id.rawValue)) {
            try await service.restart(id, executor: nil, note: "discarded")
          }
          #expect(try await sessions.hydrate(id).transcript.kernel == before.transcript.kernel)
          #expect(try await sessions.generationState(id).generation == before.generation)
        }
        #expect(!cancelled.value)
        if pass == .inference {
          release.release()
          try await until("the original reply committed") { committed.value }
          _ = try await service.restart(id, executor: nil, note: "fresh")
        }
        if pass == .inference || pass == .committedTail {
          let fresh = try await sessions.hydrate(id)
          #expect(fresh.generation == 1)
          #expect(fresh.transcript.kernel.assistantEntries.isEmpty)
        }
      } catch {
        release.release()
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }

  @Test func forceArchiveCancelsAnActiveCompactionAndRunsMainCleanup() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "force compact archive", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false), cancelled = Box(false), cleaned = Box<[SessionID]>([])
      let release = Latch()
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: makeConfig(inference: { _ in
        await withTaskCancellationHandler {
          entered.withLock { $0 = true }
          await release.wait(unless: { Task.isCancelled })
        } onCancel: { cancelled.withLock { $0 = true } }
        try Task.checkCancellation()
        return Fix.reply("discarded")
      }))
      let service = SessionService(sessions: sessions, worker: worker, archived: { id in cleaned.withLock { $0.append(id) } })
      do {
        try await sessions.requestCommand(id, .compact(instructions: nil))
        try await service.wake(id)
        try await until("compaction entered") { entered.value }
        try await service.archive(id, force: true)
        #expect(cancelled.value)
        #expect(try await sessions.record(id).lifecycle != .live)
        #expect(cleaned.value == [id])
        #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.isEmpty)
      } catch {
        release.release()
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }

  @Test(arguments: [false, true])
  func failedWriteOrRacingDeliveryReloadsTheRevokedSession(writeFailure: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "restart rollback", kind: .agent, createdBy: "morgan", model: .test)
      let previous = Fix.reply("previous generation history")
      try await sessions.appendAssistant(id, attemptID: UUID(), message: previous.message, metadata: previous.metadata)
      let prefix = try await sessions.hydrate(id).transcript.kernel.items
      if writeFailure {
        try await space.writer.write { db in
          try db.execute(sql: "CREATE TRIGGER refuse_restart BEFORE INSERT ON session_pointers WHEN NEW.generation = 1 BEGIN SELECT RAISE(ABORT, 'restart write refused'); END")
        }
      }
      let seen = Box<[Transcript]>([])
      var config = makeConfig(inference: { request in
        seen.withLock { $0.append(request.transcript) }
        return Fix.reply("reloaded work finished")
      })
      config.runningWork = { _ in
        if !writeFailure { _ = try await sessions.enqueue(id, input: Fix.message("racing delivery")) }
        return ["exec.detached"]
      }
      let worker = await SessionExecution(main: Hub(space: space), loopConfig: config)
      let service = SessionService(sessions: sessions, worker: worker)
      do {
        if writeFailure {
          await #expect(throws: DatabaseError.self) { try await service.restart(id, executor: nil, note: "discarded") }
          _ = try await service.enqueue(item: Fix.message("after failure"), to: id)
        } else {
          await #expect(throws: SessionStoreError.busyForRestart(id.rawValue)) { try await service.restart(id, executor: nil, note: "discarded") }
        }
        try await until("reload admits work after rollback") { try await sessions.settledWork(id) && seen.value.count == 1 }
        #expect(try await sessions.generationState(id).generation == 0)
        #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.count == 2)
        #expect(Array(try #require(seen.value.first).items.prefix(prefix.count)) == prefix)
      } catch {
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }
}
