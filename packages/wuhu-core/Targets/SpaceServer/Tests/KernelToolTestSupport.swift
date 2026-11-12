#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import StructuredQueries
import Testing
import WuhuAI

// Parks until the task is cancelled, then runs `then`: what a test's worker
// or scripts do when its task group ends.
func whenCancelled(_ then: @Sendable () async -> Void) async {
  let (parked, end) = AsyncStream<Void>.makeStream()
  for await _ in parked {}
  end.finish()
  await then()
}

func callResult(
  _ harness: SessionHarness,
  _ session: String,
  tool: String,
  _ arguments: JSONValue,
) async throws -> JSONValue {
  let id = SessionID(session)
  let state = harness.toolStates.values.withLock { $0[id] ?? ToolExecutionState() }
  let callID = UUID().uuidString.lowercased()
  let call = ToolCall(id: callID, name: tool, arguments: ToolArguments(arguments))
  if tool == "run_script" {
    let cell = SessionCell.ID(session)
    try await harness.space.worker.call(cell) { cell in
      let hydration = try cell.rows.hydrate(id)
      var turn = cell.turn() ?? SessionTurn(generation: hydration.generation, position: 1)
      turn.position += 1
      turn.turn = .tools(calls: [call])
      turn.replied = true
      turn.armed = true
      try cell.db.execute(SessionTurn.delete())
      try cell.db.execute(SessionTurn.insert { turn })
      let slot = Slot(session: id, generation: turn.generation, position: turn.position, stepTry: 0)
      try cell.startScript(slot.call, call, ScriptPlan(call))
    }
    var result: JSONValue?
    try await until("the script job answers") {
      for line in try await harness.store.transcriptLines(id) where line.key == "call:\(callID)" {
        guard case let .toolResult(answer) = try line.line().message else { continue }
        let text = answer.content.compactMap { if case let .text(text) = $0 { text.text } else { nil } }.joined()
        result = .object(["isError": .bool(answer.isError), "content": .array([.object(["type": "text", "text": .string(text)])])])
      }
      return result != nil
    }
    return result!
  }
  let outcome = try await harness.runtime.execution.tools.execute(session: id, call: ToolCall(id: callID, name: tool, arguments: ToolArguments(arguments)), state: state)
  let payload = outcome.payload
  harness.toolStates.values.withLock {
    var state = $0[id] ?? ToolExecutionState()
    state.apply(payload)
    if let context = outcome.context {
      state.apply(delivered: .notification(context.notice(id: UUID(), at: Date(timeIntervalSince1970: 0))))
    }
    $0[id] = state
  }
  let failed: Bool = if case .failure = payload { true } else { false }
  return .object(["isError": .bool(failed), "content": .array([.object(["type": "text", "text": .string(payload.renderedText)])])])
}

func resultText(_ result: JSONValue) -> String? {
  guard case let .object(fields) = result, case let .array(blocks)? = fields["content"],
        case let .object(block)? = blocks.first, case let .string(text)? = block["text"]
  else { return nil }
  return text
}

func isToolError(_ result: JSONValue) -> Bool {
  guard case let .object(fields) = result else { return false }
  return fields["isError"] == .bool(true)
}
