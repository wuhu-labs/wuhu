import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct PressureLifecycleTests {
  @Test(arguments: [false, true])
  func cancelledBudgetResolutionCannotReadDismountedState(serviceShutdown: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "budget teardown", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Fix.message("go"))
      let entered = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let resolver = Task { for await _ in release.stream { break } }
      defer { release.continuation.finish(); resolver.cancel(); entered.continuation.finish() }
      let resolutions = Box(0)
      let inferences = Box(0)
      var config = makeConfig(inference: { _ in
        inferences.withLock { $0 += 1 }
        return Fix.reply("must not run")
      })
      config.thresholds = .init(soft: 0, hard: 100)
      config.budget = { _ in
        let count = resolutions.withLock { $0 += 1; return $0 }
        if count == 3 {
          entered.continuation.yield(())
          // Like production resolution, this deliberately returns despite cancellation.
          await resolver.value
        }
        return .init(maxInput: 1_001_000, maxOutput: 1000)
      }
      let service = await SessionService(sessions: sessions, loopConfig: config)
      let start = Task { try await service.start() }
      for await _ in entered.stream { break }
      if serviceShutdown {
        start.cancel()
        try await until("actor dismounted by shutdown") { await service.registry.existing(sid) == nil }
      } else {
        let actor = try #require(await service.registry.existing(sid))
        await actor.shutdown()
        start.cancel()
      }
      release.continuation.yield(())
      try await start.value
      #expect(inferences.value == 0)
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(pressureNotices(transcript).isEmpty)
    }
  }

  @Test func serviceRestartReusesUnfinishedTurnsDurableNotice() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "notice restart", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Fix.message("go"))
      let attempts = Box<[Transcript]>([])
      var config = makeConfig(inference: { request in
        #expect(try await sessions.hydrate(sid).transcript.kernel == request.transcript)
        let count = attempts.withLock { $0.append(request.transcript); return $0.count }
        if count < 3 {
          let parked = AsyncStream<Void>.makeStream()
          for await _ in parked.stream {}
          parked.continuation.finish()
          throw CancellationError()
        }
        return Fix.reply("done")
      })
      config.thresholds = .init(soft: 0, hard: 100)
      for round in 1 ... 3 {
        try await runService(sessions, config) { _ in
          try await until("inference before restart") { attempts.value.count == round }
          if round == 3 { try await until("settled") { try await sessions.settledWork(sid) } }
        }
        let transcript = try await sessions.hydrate(sid).transcript.kernel
        #expect(pressureNotices(transcript).count == 1)
      }
      #expect(attempts.value.count == 3)
      #expect(attempts.value.allSatisfy { $0 == attempts.value[0] })
    }
  }
}

private func pressureNotices(_ transcript: Transcript) -> [SystemNotification] {
  transcript.items.compactMap { item in
    guard case let .notification(notification) = item, notification.subscriptionID == SubscriptionID("context-pressure") else { return nil }
    return notification
  }
}
