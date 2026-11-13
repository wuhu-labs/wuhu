import Dependencies
import DeterministicDependencies
@testable import ExecSupervisor
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
@testable import LoopCore
import MachineContract
import OperationProtocol
import OperationRuntime
import SessionDomain
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import struct WuhuAI.ToolCall
import Wuwei
import WuweiQueries

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct ToolExecClosedInputTests {
  @Test func aKernelExecCatReceivesClosedInputAndReturnsEmptyOutputWithoutAStop() async throws {
    try await withSessionDeps {
      try await withDependencies {
        $0.fetch = closedInputInference()
      } operation: {
        let space = try makeMachineSpace()
        _ = try await space.fs(.settings).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
        let tokens = try await testTokens(space: space)
        let hub = MachineHub(space: space, tokens: tokens)
        let machine = try await space.addMachineV2(name: "box", group: .shared).machine.id
        let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in })
        let prepared = Gate()
        let answerMayProceed = Gate()
        let stdin = Mutex<JSONValue?>(nil)
        let stops = Mutex(0)
        let client = FetchClient { request in
          var request = request
          if request.method == .post, request.url.path.contains("/operations/") {
            let start = try await request.json(StartRequest.self)
            stdin.withLock { $0 = start.input.object?["stdin"] }
            request.body = try .json(start)
            prepared.open()
            await answerMayProceed.wait()
          }
          if request.method == .put, request.url.path.hasSuffix("/stop") { stops.withLock { $0 += 1 } }
          return try await agent.handler(request)
        }
        let runtime = await SessionRuntime.assemble(space: space, hub: hub, credentials: .init { _ in .apiKey("test-key") }, tokens: tokens)
        _ = SpaceServer.handler(space: space, hub: hub, sessions: runtime, devPerson: try await space.ensureDevPerson())
        runtime.execution.start()
        do {
          try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { await agent.run() }
            defer { tasks.cancelAll() }
            try await withMachineBox(space: space, hub: hub, machine: machine, client: client) {
              defer { answerMayProceed.open() }
              let session = try await space.sessions.createSession(
                group: .shared, title: "closed stdin", kind: .agent, createdBy: "owner",
                model: .init(provider: "testing", model: "test-model", effort: "high"),
              )
              try await space.sessions.enqueue(session, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("cat-wake"), content: .init(text: "run cat"))))
              await prepared.wait()
              try Task.checkCancellation()
              try #require(stdin.withLock { $0 } == .bool(false), "a kernel tool exec must close stdin rather than leave cat waiting for a caller")
              let calls = try await space.sessions.testLines(session).flatMap { line -> [ToolCall] in
                guard case let .assistant(reply) = line.message else { return [] }
                return reply.content.compactMap { block in
                  guard case let .toolCall(call) = block, call.name == "exec" else { return nil }
                  return call
                }
              }
              #expect(calls.count == 1)
              let call = try #require(calls.first)
              let callID = ToolCallID(call.id)
              let turn = try #require(space.worker.cell(SessionCell.ID(session.rawValue)).turn())
              let job = Slot(session: session, generation: turn.generation, position: turn.position, stepTry: 0).call
              let watch = await watchSpaceTables(["tool_calls"], in: space)
              defer { watch.cancel() }
              answerMayProceed.open()
              var recorded: ToolCallAnswer?
              for await _ in watch.changes {
                if let answer = space.worker.job(job).db.rows(CallRow.all).first?.answer { recorded = answer; break }
              }
              try Task.checkCancellation()
              let answer = try #require(recorded)
              guard case let .result(payload, _) = answer else { Issue.record("cat returned a non-result answer: \(answer)"); return }
              guard case let .exec(result) = payload else { Issue.record("cat returned a non-exec result: \(payload)"); return }
              #expect(result.output.isEmpty)
              #expect(result.exitCode == 0)
              #expect(!result.reaped)
              let record = try #require(try await space.execRecord(caller: session.rawValue, toolCallID: callID))
              #expect(record.terminal == .exited(code: 0))
              let row = try #require(space.worker.cell(MachineCell.ID(machine.rawValue)).operation(record.id.rawValue))
              #expect(row.stop == nil && !row.stopSent)
              #expect(stops.withLock { $0 } == 0)
            }
            await runtime.execution.shutdown()
            await agent.shutdown()
          }
          try await space.close()
        } catch {
          await runtime.execution.shutdown()
          await agent.shutdown()
          try await space.close()
          throw error
        }
      }
    }
  }
}

private func closedInputInference() -> FetchClient {
  let calls = Mutex(0)
  return FetchClient { _ in
    let first = calls.withLock { value in value += 1; return value == 1 }
    let content = first
      ? #"{"index":0,"content_block":{"type":"tool_use","id":"cat-call","name":"exec","input":{"machine":"box","cwd":"/","command":"cat","wait_seconds":90}}}"#
      : #"{"index":0,"content_block":{"type":"text","text":"done"}}"#
    let events = [
      ("message_start", #"{"message":{"usage":{"input_tokens":10}}}"#),
      ("content_block_start", content),
      ("content_block_stop", #"{"index":0}"#),
      ("message_delta", first ? #"{"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"# : #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
      ("message_stop", "{}"),
    ]
    let sse = events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined(separator: "")
    return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
  }
}
