#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct ServiceBootDrainTests {
  @Test func cancellationDuringBootJoinsPreviouslyStartedPassCleanup() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let first = try await sessions.createSession(group: .shared, title: "first", kind: .agent, createdBy: "morgan", model: .test)
      let second = try await sessions.createSession(group: .shared, title: "second", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(first, input: Fix.message("first input"))
      _ = try await sessions.enqueue(second, input: Fix.message("second input", message: "m2"))
      #expect(try await sessions.bootSessions() == [first, second])
      let entered = AsyncStream<Void>.makeStream()
      let bootEntered = AsyncStream<Void>.makeStream()
      let cleanupEntered = AsyncStream<Void>.makeStream()
      let releaseCleanup = AsyncStream<Void>.makeStream()
      let finished = Box(false)
      let returned = Box(false)
      let order = Box<[String]>([])
      let invalidated = Box<[SessionID]>([])
      let cleanup = Task {
        for await _ in releaseCleanup.stream { break }
      }
      defer { releaseCleanup.continuation.finish(); cleanup.cancel() }
      var config = makeConfig(inference: { request in
        guard request.sessionID == first else { return Fix.reply("done") }
        let parking = AsyncStream<Void>.makeStream()
        entered.continuation.yield(())
        for await _ in parking.stream {}
        parking.continuation.finish()
        cleanupEntered.continuation.yield(())
        await cleanup.value
        finished.withLock { $0 = true }
        order.withLock { $0.append("cleanup") }
        throw CancellationError()
      })
      config.invalidateInference = { id in invalidated.withLock { $0.append(id) } }
      let service = await SessionService(sessions: sessions, loopConfig: config) { id in
        SessionRepo(sessions: sessions, id: id, queueHeadRead: { store, id in
          if id == second {
            for await _ in entered.stream { break }
            let parking = AsyncStream<Void>.makeStream()
            bootEntered.continuation.yield(())
            for await _ in parking.stream {}
            parking.continuation.finish()
            throw CancellationError()
          }
          return try await store.queueHead(id)
        })
      }
      let start = Task {
        defer { returned.withLock { $0 = true }; order.withLock { $0.append("start") } }
        try await service.start()
      }
      for await _ in bootEntered.stream { break }
      start.cancel()
      for await _ in cleanupEntered.stream { break }
      #expect(!returned.value)
      #expect(!finished.value)
      releaseCleanup.continuation.yield(())
      try await start.value
      #expect(finished.value)
      #expect(order.value == ["cleanup", "start"])
      #expect(await service.registry.sessions.isEmpty)
      #expect(Set(invalidated.value) == Set([first, second]))
      bootEntered.continuation.finish()
      entered.continuation.finish()
      cleanupEntered.continuation.finish()
    }
  }
}
