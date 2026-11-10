import Dependencies
import Foundation
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
        Fix.replying("on it", calls: [ToolCall(id: "call_0", name: "exec", arguments: .object(["command": .string("make")]))]),
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
        try await service.enqueue(item: Fix.message("still there?", message: "m2"), to: sid)
        try await time.wake("the other input's grace", after: 90)
        try await until("second assistant reply") {
          try await sessions.hydrate(sid).transcript.kernel.assistantEntries.count == 2
        }
      }

      let items = try await sessions.hydrate(sid).transcript.kernel.items
      let results = items.compactMap { item -> String? in
        guard case let .toolResult(result) = item, case let .exec(exec) = result.payload else { return nil }
        return exec.output
      }
      #expect(results == ["yielded"])
      #expect(script.attempts.value.last?.itemCount == items.count - 1)
    }
  }
}
