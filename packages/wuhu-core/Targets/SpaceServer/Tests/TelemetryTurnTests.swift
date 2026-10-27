import DeterministicDependencies
import class MainHub.Hub
import class MainHub.SessionService
import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
import Logging
import LoopCore
import Scratch
import ServerTelemetry
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

@Test(.deterministicDependencies) func telemetryRecordsARealTurnWithoutMessageArgumentsOrResults() async throws {
  let spans = Mutex<[FinishedSpan]>([])
  try await ServerTracing.$emitter.withValue({ span in spans.withLock { $0.append(span) } }) {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(group: .shared, title: "secret title", kind: .agent, createdBy: "owner", model: .init(provider: "test", model: "model", effort: "high"))
      let folder = try ScratchFolder("otel-turn")
      let logger = Logger(label: "test.telemetry")
      let writer = InferenceMetricsWriter(folder: folder.url, logger: logger)
      let metrics = inferenceMetricsSink(space: space, writer: writer, logger: logger)
      let attempts = Mutex(0)
      let config = LoopConfig(executeTool: { invocation in
        #expect(invocation.call.name == "exec")
        let operation = ServerSpan(.machine)
        operation.finish([.machine: "devbox", .version: "v1", .kind: "exec", .exitCode: "0", .outcome: "ok"])
        return ToolOutcome(payload: .exec(.init(output: "secret output", exitCode: 0)))
      }, inference: { request in
        let attempt = attempts.withLock { count in count += 1; return count }
        await metrics.record(.init(timestamp: Date(), payer: .session(request.sessionID), provider: "test", model: "model", effort: "high", outcome: .ok, ttftMs: 10, durationMs: 20, usage: .init(inputTokens: 5, outputTokens: 3, totalTokens: 8)))
        let blocks: [ContentBlock] = attempt == 1 ? [.toolCall(.init(id: "call", name: "exec", arguments: .init(.object(["machine": "devbox", "command": "secret command"]))))] : [.text("secret response")]
        return .init(message: .init(content: blocks), metadata: .init(stopReason: .stop, usage: .init(inputTokens: 5, outputTokens: 3, totalTokens: 8)))
      }, compact: { _, _ in .init(summary: "") }, budget: { _ in .init(maxInput: 100_000, maxOutput: 1000) })
      let owner = Hub(space: space)
      let worker = await SessionExecution(main: owner, connection: MainConnection(), credential: { _ in throw MainUnavailable() }) { _ in config }
      let service = SessionService(sessions: space.sessions, worker: worker)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await service.start() }
        defer { group.cancelAll() }
        _ = try await service.enqueue(item: .message(.init(id: UUID(), messageID: .init("message"), conversationID: .init("conversation"), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), owesReply: false, content: .init(text: "secret message"))), to: session)
        try await until("completed traced turn") { spans.withLock { $0.contains { $0.name == .turn } && $0.filter { $0.name == .inference }.count == 2 } }
      }
      await writer.close()
      let snapshot = spans.withLock { $0 }
      let tool = try #require(snapshot.first { $0.name == .tool })
      let turn = try #require(snapshot.first { $0.context.spanID == tool.parentSpanID })
      #expect(turn.name == .turn)
      #expect(snapshot.filter { $0.name == .inference }.allSatisfy { $0.parentSpanID == turn.context.spanID })
      #expect(snapshot.first { $0.name == .machine }?.parentSpanID == tool.context.spanID)
      #expect(snapshot.allSatisfy { $0.context.session == session.rawValue && $0.context.group == "shared" })
      #expect(tool.attributes[.machineReference] == "devbox")
      #expect(tool.attributes[.bytesIn] != nil && tool.attributes[.bytesOut] != nil)
      #expect(snapshot.first { $0.name == .inference }?.attributes[.ttftMs] == "10")
      let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
      #expect(!encoded.contains("secret"))
    }
  }
}
