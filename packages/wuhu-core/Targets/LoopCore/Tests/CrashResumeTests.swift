import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct CrashResumeTests {
  @Test func `boot retries an orphaned tool call against a fresh service and converges`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions

      // The "crashed" run: a committed assistant turn whose tool call never
      // got a result. No service ever saw this state.
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Fix.message("run the build"))
      _ = try await sessions.drainQueue(sid)
      _ = try await sessions.appendAssistant(
        sid,
        attemptID: UUID(),
        message: .init(content: [
          .text("on it"),
          .toolCall(.init(id: "call_0", name: "exec", arguments: .object(["command": .string("make")]))),
        ]),
        metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 50)),
      )
      #expect(try await sessions.bootSessions() == [sid])

      let script = InferenceScript([
        Fix.replying("build finished"),
      ])
      let exec = ExecScript { _ in
        .exec(.init(output: "ok", exitCode: 0))
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      try await runService(sessions, config) { _ in
        // No verb: boot alone must surface the orphan FIFO and converge.
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(exec.calls.value.map(\.name) == ["exec"])
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.pendingToolCallIDs.isEmpty)
      guard case let .toolResult(result) = transcript.items[2],
            case .exec = result.payload
      else {
        Issue.record("expected the retried exec result in place")
        return
      }
      #expect(transcript.assistantEntries.count == 2)
      guard case .assistant = transcript.items.last else {
        Issue.record("expected the follow-up assistant turn to end the transcript")
        return
      }
    }
  }

  @Test func `an interrupted orphan stays parked at boot and surfaces on resume`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions

      // Interrupted mid-tool-call, then "crashed": boot materializes it but
      // the hold parks the loop; the orphan surfaces only once resumed.
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Fix.message("run the build"))
      _ = try await sessions.drainQueue(sid)
      _ = try await sessions.appendAssistant(
        sid,
        attemptID: UUID(),
        message: .init(content: [
          .toolCall(.init(id: "call_0", name: "exec", arguments: .object([:]))),
        ]),
        metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 50)),
      )
      try await sessions.markInterrupted(sid)

      let script = InferenceScript([Fix.replying("done")])
      let exec = ExecScript { _ in .exec(.init(output: "ok", exitCode: 0)) }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      try await runService(sessions, config) { service in
        try await holds("interrupted session stays parked") { exec.calls.value.isEmpty }
        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(exec.calls.value.count == 1)
    }
  }
}
