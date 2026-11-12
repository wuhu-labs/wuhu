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
  @Test func serviceRestartReusesUnfinishedTurnsDurableNotice() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "notice restart", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.enqueue(sid, input: Fix.message("go"))
      let attempts = Box<[[TranscriptLine]]>([])
      var config = makeConfig(inference: { request in
        #expect(try await sessions.lines(sid) == request.lines)
        let count = attempts.withLock { $0.append(request.lines); return $0.count }
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
        try await runService(space, config) { _ in
          try await until("inference before restart") { attempts.value.count == round }
          if round == 3 { try await until("settled") { try await sessions.settledWork(sid) } }
        }
        let lines = try await sessions.lines(sid)
        #expect(pressureNotices(lines).count == 1)
      }
      #expect(attempts.value.count == 3)
      #expect(attempts.value.allSatisfy { $0 == attempts.value[0] })
    }
  }
}

private func pressureNotices(_ lines: [TranscriptLine]) -> [TranscriptLine] {
  lines.filter { $0.key == LineKey.pressure }
}
