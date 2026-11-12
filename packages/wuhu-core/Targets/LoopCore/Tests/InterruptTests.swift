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

@Suite struct InterruptTests {
  @Test func `interrupt cancels a mid-backoff sleep promptly and resume re-arms via its nudge`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
        mirrorAllocationDraws(&rng)
        let backoff = min(backoffCeiling, 1) * Double.random(in: 0 ... 1, using: &rng)
        try await time.asleep("backoff 1", dueIn: backoff)

        // No clock advance: the interrupt must cancel the pending sleep.
        try await service.interrupt(sid)
        try await until("interrupted") { try await sessions.record(sid).hold == .interrupted }
        try await until("backoff cancelled") { time.sleeping(dueIn: backoff) == 0 }

        // Time passing while interrupted must not retry.
        await time.advance(by: 120)
        try await holds("no retry while interrupted") { script.count == 1 }

        try await service.resume(sid)
        try await until("retry after resume") { script.count == 2 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(try await sessions.lines(sid).assistantLines.count == 1)
    }
  }

  @Test func `interrupt marks the running tool interrupted and resume never retries it`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("running exec", calls: [.init(id: "call_0", name: "test_tool", arguments: .object([:]))]),
        Fix.replying("recovered"),
      ])
      let exec = ExecScript { _ in
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .seconds(1_000_000))
        throw UnexpectedCall("hanging exec elapsed")
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("run it"), to: sid)
        try await until("executor engaged") { exec.calls.value.count == 1 }

        try await service.interrupt(sid)
        try await until("interrupted marker") {
          try await sessions.lines(sid).last?.role == .toolResult
        }
        #expect(try await sessions.record(sid).hold == .interrupted)

        let held = try await sessions.lines(sid)
        let marker = try #require(held.last?.message.toolResult)
        #expect(marker.isError)
        #expect(marker.content == [.text(interruptedToolMessage)])
        #expect(marker.toolCallId == exec.calls.value.first?.id)
        #expect(space.worker.cell(SessionCell.ID(sid.rawValue)).turn()?.call == nil)

        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      // The marker satisfied the call: the executor never ran a second time.
      #expect(exec.calls.value.map(\.name) == ["test_tool"])
      #expect(try await sessions.lines(sid).assistantLines.count == 2)
    }
  }

  @Test func `interrupt during an in-flight render or stream cancels the attempt cleanly`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.hanging,
        Fix.replying("after resume"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt in flight") { script.count == 1 }

        try await service.interrupt(sid)
        try await until("interrupted") { try await sessions.record(sid).hold == .interrupted }
        #expect(try await sessions.lines(sid).assistantLines.isEmpty)

        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let attempts = script.attempts.value
      #expect(attempts.count == 2)
      #expect(attempts[0].id != attempts[1].id)
      let lines = try await sessions.lines(sid)
      #expect(lines.assistantLines.map(\.key) == ["attempt:\(attempts[1].id.uuidString.lowercased())"])
    }
  }
}
