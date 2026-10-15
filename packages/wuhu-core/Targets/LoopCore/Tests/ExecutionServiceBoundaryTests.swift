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
}
