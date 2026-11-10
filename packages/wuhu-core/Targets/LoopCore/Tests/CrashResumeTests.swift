import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct CrashResumeTests {
  @Test func `an interrupted orphan stays parked at boot and surfaces on resume`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions

      // Interrupted mid-tool-call, then "crashed": boot materializes it but
      // the hold parks the loop; the orphan surfaces only once resumed.
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.put(sid, input: Fix.message("run the build"))
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

      try await runService(space, config) { service in
        try await holds("interrupted session stays parked") { exec.calls.value.isEmpty }
        try await service.resume(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(exec.calls.value.count == 1)
    }
  }
}
