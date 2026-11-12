import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct YieldTests {
  @Test func `a running exec gives the turn back once input has waited out its grace`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("on it", calls: [ToolCall(id: "call_0", name: "test_tool", arguments: .object(["command": .string("make")]))]),
        Fix.replying("done"),
      ])
      let started = Latch()
      var config = makeConfig(inference: { try await script($0) })
      config.executeTool = { invocation in
        started.release()
        let yielded = await invocation.yielded()
        return ToolOutcome(payload: .exec(.init(output: yielded ? "yielded" : "finished", exitCode: 0)))
      }

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("build"), to: sid)
        await started.wait()
        let turn = try #require(space.worker.cell(SessionCell.ID(sid.rawValue)).turn())
        let call = Slot(session: sid, generation: turn.generation, position: turn.position, stepTry: 0).call
        try await service.enqueue(item: Fix.message("still there?", message: "m2"), to: sid)
        try await time.wake("the other input's grace", after: 90)
        try await until("the yielded tool answer is durable") {
          guard case let .result(.exec(result), _)? = space.worker.job(call).db.rows(CallRow.all).first?.answer else { return false }
          return result.output == "yielded"
        }
        try await time.wake("the scan after the session's idle eviction", after: 1)
        try await until("second assistant reply") {
          try await sessions.lines(sid).assistantLines.count == 2
        }
      }

      let lines = try await sessions.lines(sid)
      let results = lines.filter { $0.role == .toolResult }
      #expect(results.map(\.text) == ["yielded"])
      #expect(script.attempts.value.last?.itemCount == lines.count - 1)
    }
  }
}
