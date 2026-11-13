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
import WuhuAI

@Suite struct SubscriptionReconciliationTests {
  @Test func afterStartOverTheFirstRequestListsTheWorkStillRunning() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([
        { request in
          let text = request.lines.map(\.text).joined(separator: "\n")
          #expect(text.contains("running: exec.ex_0a1b2c3d, script.ffff0000"))
          return Fix.reply("done")
        },
      ])
      var config = makeConfig(inference: { try await script($0) })
      let running = Box(["script.ffff0000", "exec.ex_0a1b2c3d"])
      config.runningWork = { session async throws in
        let record = try await sessions.record(session)
        #expect(record.title == "running work")
        return running.value
      }
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await sessions.createSession(group: .shared, title: "running work", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        _ = try await service.restart(id, executor: nil, note: nil)
        running.withLock { $0 = [] }
        try await service.enqueue(item: Fix.message("what is still running?"), to: id)
        try await until("the fresh generation answers") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(id)
        }
      }
    }
  }
}
