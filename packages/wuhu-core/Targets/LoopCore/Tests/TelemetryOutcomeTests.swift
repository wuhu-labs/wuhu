import Dependencies
import Foundation
import InMemoryTracing
import JSONValue
@testable import LoopCore
import ServerTelemetry
import SessionDomain
import SpaceCore
import Testing
import Tracing
import WuhuAI

extension [FinishedInMemorySpan] {
  fileprivate func named(_ name: String) -> Self { filter { $0.operationName == name } }
}

private func outcome(_ span: FinishedInMemorySpan) -> SpanAttribute? { span.attributes.get("wuhu.outcome") }

@Test func invalidKernelToolsAndExecutorErrorsRecordFailureOutcomes() async throws {
  let tracer = InMemoryTracer()
  try await withDependencies { $0.tracer = tracer } operation: {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
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
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: id)
        try await until("five failed tools") { tracer.finishedSpans.filter { $0.operationName == "tool.call" }.count == 5 }
      }
      let tools = tracer.finishedSpans.filter { $0.operationName == "tool.call" }
      #expect(tools.allSatisfy { outcome($0) == .string("errored") && $0.status?.code == .error })
      // The thrown compaction wrote no result, so it has no size.
      #expect(tools.filter { $0.attributes.get("wuhu.bytes.out") != nil }.count == 4)
      let folds = tracer.finishedSpans.named("agent.compaction")
      #expect(folds.count == 2)
      #expect(folds.allSatisfy { fold in
        fold.attributes.get("wuhu.compaction.reason") == .string("tool") && outcome(fold) == .string("errored") && tools.contains { $0.spanID == fold.parentSpanID }
      })
      for span in tracer.finishedSpans {
        span.attributes.forEach { _, value in #expect(!"\(value)".contains("secret")) }
      }
    }
  }
}

@Test func aTurnIsOneTraceOfItsInferencesToolsAndInputs() async throws {
  let tracer = InMemoryTracer()
  try await withDependencies { $0.tracer = tracer } operation: {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "t", kind: .task, createdBy: "morgan", model: .test, snapshot: .init())
      let inference = InferenceScript([Fix.replying("", calls: [.init(id: "exec", name: "exec", arguments: .init(["machine": "devbox", "command": "secret"]))]), Fix.replying("done")])
      let config = makeConfig(executeTool: { _ in .exec(.init(output: "out", exitCode: 0)) }, inference: { try await inference($0) })
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello", message: "m7"), to: id)
        try await until("a finished turn") { tracer.finishedSpans.contains { $0.operationName == "agent.turn" } }
      }
      let spans = tracer.finishedSpans
      let turn = try #require(spans.first { $0.operationName == "agent.turn" })
      #expect(turn.parentSpanID == nil)
      #expect(spans.allSatisfy { $0.traceID == turn.traceID })
      #expect(spans.allSatisfy { $0.attributes.get("wuhu.session.id") == .string(id.rawValue) && $0.attributes.get("wuhu.group.id") == .string("shared") })
      #expect(turn.attributes.get("wuhu.trigger") == .string("message"))
      #expect(turn.attributes.get("wuhu.session.kind") == .string("task"))
      #expect(turn.attributes.get("wuhu.input.message_ids") == .stringArray(["m7"]))
      #expect(turn.attributes.get("wuhu.queue.wait_ms") != nil)
      #expect(turn.attributes.get("wuhu.steps") == .int64(2))
      #expect(turn.attributes.get("wuhu.tool_calls") == .int64(1))
      #expect(outcome(turn) == .string("ok"))
      let inferences = spans.filter { $0.operationName == "agent.inference" }
      #expect(inferences.count == 2)
      #expect(inferences.allSatisfy { $0.parentSpanID == turn.spanID && $0.attributes.get("wuhu.attempts") == .int64(1) && outcome($0) == .string("ok") })
      let tool = try #require(spans.first { $0.operationName == "tool.call" })
      #expect(tool.parentSpanID == turn.spanID)
      #expect(tool.attributes.get("gen_ai.tool.name") == .string("exec"))
      #expect(tool.attributes.get("wuhu.bytes.out") == .int64(3))
      #expect(tool.attributes.get("wuhu.running") == .bool(false))
    }
  }
}

@Test func aRestartedTurnKeepsItsTriggerAndRecordsLaterInputsAsEvents() async throws {
  let tracer = InMemoryTracer()
  try await withDependencies { $0.tracer = tracer } operation: {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(id, input: Fix.message("run the build", message: "m1"))
      _ = try await sessions.drainQueue(id)
      _ = try await sessions.appendAssistant(
        id,
        attemptID: UUID(),
        message: .init(content: [.toolCall(.init(id: "call_0", name: "exec", arguments: .object([:])))]),
        metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 50)),
      )
      _ = try await sessions.enqueue(id, input: Fix.message("and then", message: "m2"))
      #expect(try await sessions.bootSessions() == [id])
      let inference = InferenceScript([Fix.replying("done")])
      let config = makeConfig(executeTool: { _ in .exec(.init(output: "ok", exitCode: 0)) }, inference: { try await inference($0) })
      try await runService(space, config) { _ in
        try await until("a finished turn") { tracer.finishedSpans.contains { $0.operationName == "agent.turn" } }
      }
      let turn = try #require(tracer.finishedSpans.named("agent.turn").first)
      #expect(turn.attributes.get("wuhu.trigger") == .string("restart"))
      #expect(turn.attributes.get("wuhu.input.message_ids") == nil)
      #expect(turn.attributes.get("wuhu.queue.wait_ms") == nil)
      #expect(turn.events.map(\.name) == ["wuhu.input.drained"])
      let drained = try #require(turn.events.first)
      #expect(drained.attributes.get("wuhu.input.message_ids") == .stringArray(["m2"]))
      #expect(drained.attributes.get("wuhu.queue.wait_ms") != nil)
    }
  }
}

@Test func tracingChangesNothingTheModelSees() async throws {
  func run(traced: Bool) async throws -> (contexts: [Context], transcript: Transcript) {
    try await withDependencies { if traced { $0.tracer = InMemoryTracer() } } operation: {
      try await withKernelDeps { _ in
        let space = try Space.inMemory()
        let id = try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init())
        let contexts = Box<[Context]>([])
        let inference = InferenceScript([Fix.replying("", calls: [.init(id: "exec", name: "exec", arguments: .init(["command": "ls"]))]), Fix.replying("done")])
        let config = makeConfig(executeTool: { _ in .exec(.init(output: "out", exitCode: 0)) }, inference: { request in
          let context = await request.transcript.renderRequest(session: request.sessionID, systemPrompt: "prompt")
          contexts.withLock { $0.append(context) }
          return try await inference(request)
        })
        let input = QueueInput.message(.init(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!, messageID: .init("m1"), conversationID: .init("c1"), sender: Fix.sender, timestamp: Date(timeIntervalSince1970: 0), owesReply: false, content: .init(text: "hello")))
        try await runService(space, config) { service in
          _ = try await service.enqueue(item: input, to: id)
          try await until("two inferences") {
            guard contexts.value.count == 2 else { return false }
            return try await space.sessions.hydrate(id).transcript.kernel.assistantEntries.count == 2
          }
        }
        return (contexts.value, try await space.sessions.hydrate(id).transcript.kernel)
      }
    }
  }
  let untraced = try await run(traced: false)
  let traced = try await run(traced: true)
  #expect(traced.contexts == untraced.contexts)
  #expect(traced.transcript == untraced.transcript)
}
