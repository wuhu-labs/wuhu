import Foundation
import JSONValue
@testable import LoopCore
import ServerTelemetry
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Test func invalidKernelToolsAndExecutorErrorsRecordFailureOutcomes() async throws {
  let spans = Box<[FinishedSpan]>([])
  try await ServerTracing.$emitter.withValue({ span in spans.withLock { $0.append(span) } }) {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init())
      let calls: [ToolCall] = [
        .init(id: "bookmark", name: "bookmark", arguments: .init(["name": 42])),
        .init(id: "compact-invalid", name: "compact", arguments: .init([:])),
        .init(id: "compact-missing", name: "compact", arguments: .init(["summary": "secret", "bookmark": "missing"])),
        .init(id: "exec", name: "exec", arguments: .init([:])),
        .init(id: "compact-thrown", name: "compact", arguments: .init(["summary": "secret"])),
      ]
      let inference = InferenceScript([Fix.replying("", calls: calls), Fix.replying("done")])
      var config = makeConfig(executeTool: { _ in throw UnexpectedCall("secret failure") }, inference: { try await inference($0) })
      config.prepareCompaction = { _, _, _ in throw UnexpectedCall("secret compaction failure") }
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: id)
        try await until("five failed tools") { spans.value.filter { $0.name == .tool }.count == 5 }
      }
      #expect(spans.value.filter { $0.name == .tool }.allSatisfy { $0.attributes[.outcome] == "error" })
      #expect(spans.value.filter { $0.name == .tool }.allSatisfy { $0.attributes[.bytesOut] != nil })
      let actor = SessionActor(id: id, main: InProcessMainClient(sessions: sessions), loopConfig: makeConfig(), liveness: LivenessTracker())
      await #expect(throws: (any Error).self) { try await actor.execute(calls[3]) }
      #expect(spans.value.last?.attributes[.outcome] == "cancelled")
    }
  }
}
