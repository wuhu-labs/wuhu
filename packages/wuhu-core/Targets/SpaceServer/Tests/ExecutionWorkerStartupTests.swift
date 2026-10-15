#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import ExecutionOwner
import Fetch
import LoopCore
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerStartupTests {
  @Test func shutdownStopsConnectionReturnedByCancellationIgnoringStartup() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "startup race", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let entered = AsyncStream<Void>.makeStream()
      let cancelled = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      let lifetime = Task { let (stream, continuation) = AsyncStream<Void>.makeStream(); for await _ in stream {}; continuation.finish() }
      defer { entered.continuation.finish(); cancelled.continuation.finish(); release.continuation.finish(); gate.cancel(); lifetime.cancel() }
      let fetch = FetchClient { _ in throw WorkerProtocolError(.unavailable, message: "fixture") }
      let client = try WorkerClient(socket: "/tmp/fixture.sock", token: "fixture", control: fetch, bytes: fetch)
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { _, _ in
        entered.continuation.yield(())
        return await withTaskCancellationHandler {
          await gate.value
          return WorkerConnection(processID: 123, client: client, lifetime: lifetime)
        } onCancel: { cancelled.continuation.yield(()) }
      })
      let wake = Task { try await worker.wake(id) }
      for await _ in entered.stream { break }
      let shutdown = Task { await worker.shutdown() }
      let secondShutdown = Task { await worker.shutdown() }
      for await _ in cancelled.stream { break }
      release.continuation.yield(())
      await shutdown.value
      await secondShutdown.value
      _ = await wake.result
      #expect(lifetime.isCancelled)
      #expect(await worker.processID == nil)
    }
  }

  @Test func overlappingPassCleanupKeepsReplacementPassAttributedToWorker() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "overlapping passes", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let fetch = FetchClient { _ in throw WorkerProtocolError(.unavailable, message: "fixture") }
      let client = try WorkerClient(socket: "/tmp/fixture.sock", token: "fixture", control: fetch, bytes: fetch)
      let lifetime = Task { let (stream, continuation) = AsyncStream<Void>.makeStream(); for await _ in stream {}; continuation.finish() }
      defer { lifetime.cancel() }
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { activity, _ in
        let old = UUID(), replacement = UUID()
        try await activity(.init(session: id, pass: old, active: true))
        try await activity(.init(session: id, pass: replacement, active: true))
        try await activity(.init(session: id, pass: old, active: false))
        #expect(try await space.sessions.recordWorkerLoss() == [id: false])
        return WorkerConnection(processID: 123, client: client, lifetime: lifetime)
      })
      _ = await Task { try await worker.wake(id) }.result
      await worker.shutdown()
    }
  }

  @Test func replacementParentFinalizesOrphanAndFencesBeforeStartingAnotherChild() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "parent replacement", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      for _ in 0 ..< 2 {
        let incarnation = UUID()
        try await space.sessions.setWorkerActivity(id, incarnation: incarnation, active: true)
        _ = try await space.sessions.recordWorkerLoss(incarnation: incarnation)
      }
      try await space.sessions.setWorkerActivity(id, incarnation: UUID(), active: true)
      let replacement = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { _, _ in
        Issue.record("a fenced session must not start a fourth incarnation")
        throw CancellationError()
      })
      try await replacement.wake(id)
      #expect(try await space.sessions.record(id).errorMessage == ExecutionWorkerCrashLoop(session: id).description)
      #expect(await replacement.processID == nil)
      await replacement.shutdown()
    }
  }

  @Test func unavailableStartupIsClassifiedAsRetryableRetirement() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "failed startup", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { _, _ in
        throw WorkerProtocolError(.unavailable, message: "admission connection lost")
      })
      await #expect(throws: SessionExecutionRetired.self) { try await worker.wake(id) }
      #expect(try await space.sessions.record(id).work != .errored)
      await worker.shutdown()
    }
  }
}
