import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct InterruptTests {
  @Test func `interrupt cancels a mid-backoff sleep promptly and resume re-arms via its nudge`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.transient(status: 503, body: nil)),
        Fix.replying("done"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt 1") { script.count == 1 }
        var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
        mirrorAllocationDraws(&rng)
        try await time.asleep("backoff 1", dueIn: min(backoffCeiling, 1) * Double.random(in: 0 ... 1, using: &rng))

        // No clock advance: the interrupt must cancel the pending sleep.
        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .interrupted)

        // Time passing while interrupted must not retry.
        await time.advance(by: 120)
        try await holds("no retry while interrupted") { script.count == 1 }

        try await service.resume(sid)
        try await until("retry after resume") { script.count == 2 }
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.count == 1)
    }
  }

  @Test func `interrupt marks the running tool interrupted and resume never retries it`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("running exec", calls: [.init(id: "call_0", name: "exec", arguments: .object([:]))]),
        Fix.replying("recovered"),
      ])
      let exec = ExecScript { _ in
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .seconds(1_000_000))
        throw UnexpectedCall("hanging exec elapsed")
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("run it"), to: sid)
        try await until("executor engaged") { exec.calls.value.count == 1 }

        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .interrupted)

        let held = try await sessions.hydrate(sid).transcript.kernel
        guard case let .toolResult(marker) = held.items.last else {
          Issue.record("expected an interrupted-tool marker")
          return
        }
        guard case let .failure(failure) = marker.payload else {
          Issue.record("expected a failure payload on the marker")
          return
        }
        #expect(failure.message.contains("interrupted"))
        #expect(held.pendingToolCallIDs.isEmpty)

        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      // The marker satisfied the call: the executor never ran a second time.
      #expect(exec.calls.value.map(\.name) == ["exec"])
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.count == 2)
    }
  }

  @Test func `a cancelled executor returning a real result gets it committed`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("running exec", calls: [.init(id: "call_0", name: "exec", arguments: .object([:]))]),
        Fix.replying("recovered"),
      ])
      let exec = ExecScript { _ in
        @Dependency(\.continuousClock) var clock
        // The side effect happened; swallow the cancellation and report it.
        try? await clock.sleep(for: .seconds(1_000_000))
        return .exec(.init(output: "side effect happened", exitCode: 0))
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("run it"), to: sid)
        try await until("executor engaged") { exec.calls.value.count == 1 }
        try await service.interrupt(sid)

        let held = try await sessions.hydrate(sid).transcript.kernel
        guard case let .toolResult(result) = held.items.last,
              case let .exec(execResult) = result.payload
        else {
          Issue.record("expected the real exec result committed")
          return
        }
        #expect(execResult.output == "side effect happened")

        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }
    }
  }

  @Test func `interrupt during an in-flight render or stream cancels the attempt cleanly`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.hanging,
        Fix.replying("after resume"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("attempt in flight") { script.count == 1 }

        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .interrupted)
        let held = try await sessions.hydrate(sid).transcript.kernel
        #expect(held.assistantEntries.isEmpty)

        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let attempts = script.attempts.value
      #expect(attempts.count == 2)
      #expect(attempts[0].id != attempts[1].id)
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.map(\.id) == [attempts[1].id])
    }
  }
}
