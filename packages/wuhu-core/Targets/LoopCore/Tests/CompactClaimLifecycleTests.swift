import GRDB
import class MainHub.Hub
import struct MainHub.SessionAccess
import class MainHub.SessionService
import struct MainHub.SubtreeArchiveBusy
import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct CompactClaimLifecycleTests {
  @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], [nil, "keep the notes"] as [String?])
  func teardownDuringClaimPreservesOrIntentionallyDiscardsCommand(ordering: (restart: Bool, beforeWrite: Bool), instructions: String?) async throws {
    let (restart, beforeWrite) = ordering
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "claim teardown", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.requestCommand(id, .compact(instructions: instructions))
      let entered = Box(false)
      let gate = Latch()
      let hub = Hub(space: space, sessionAccess: {
        var access = SessionAccess()
        let hold: @Sendable (SessionID) async throws -> Void = { _ in
          entered.withLock { $0 = true }
          await gate.wait(unless: { Task.isCancelled })
        }
        if beforeWrite { access.beforeClaim = hold } else { access.afterClaim = hold }
        return access
      }())
      let service = await SessionService(sessions: sessions, main: hub, loopConfig: makeConfig())
      do {
        try await service.wake(id)
        try await until("compact claim held") { entered.value }
        if restart {
          try await sessions.markInterrupted(id)
          await #expect(throws: SessionStoreError.busyForRestart(id.rawValue)) { try await service.restart(id, executor: nil, note: nil) }
        }
        await service.shutdown()
        #expect(try await sessions.pendingCommand(id) == .compact(instructions: instructions))

      } catch {
        gate.release()
        await service.shutdown()
        throw error
      }
    }
  }

  @Test(arguments: [false, true])
  func legacyCommandDeletionOrReplacementDoesNotGiveATokenRuntimeMeaning(replacement: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "legacy token", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.requestCommand(id, .compact(instructions: nil))
      #expect(try await sessions.claimCompactRequest(id, generation: 0) != nil)
      try await space.writer.write { db in
        if replacement {
          try db.execute(sql: "UPDATE session_commands SET created_at = ? WHERE session_id = ?", arguments: ["2026-10-14T11:17:16.000Z", id.rawValue])
        } else {
          try db.execute(sql: "DELETE FROM session_commands WHERE session_id = ?", arguments: [id.rawValue])
        }
      }
      let entered = Box(false)
      let release = Latch()
      let service = await SessionService(sessions: sessions, main: Hub(space: space), loopConfig: makeConfig(inference: { request in
        if request.mode == .forcedCompact {
          entered.withLock { $0 = true }
          await release.wait(unless: { Task.isCancelled })
          return Fix.reply("folding", calls: [.init(id: "compact", name: "compact", arguments: .object(["summary": .string("folded")]))])
        }
        return Fix.reply("done")
      }))
      do {
        try await service.wake(id)
        if replacement {
          try await until("replacement command runs") { entered.value }
          await #expect(throws: SubtreeArchiveBusy.self) { try await service.archive(id) }
          release.release()
          try await until("replacement compact settles") {
            guard try await sessions.settledWork(id) else { return false }
            return try await sessions.pendingCommand(id) == nil
          }
        }
        #expect(try await sessions.pendingCommand(id) == nil)
        try await until("compact completion allows archive") {
          do {
            try await service.archive(id)
            return true
          } catch is SubtreeArchiveBusy {
            return false
          }
        }
        #expect(try await sessions.record(id).lifecycle != .live)
      } catch {
        release.release()
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }
}
