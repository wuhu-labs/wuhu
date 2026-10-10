#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import SessionTools
@testable import SpaceServer
import Testing
import WuhuAI

func callResult(
  _ harness: SessionHarness,
  _ session: String,
  tool: String,
  _ arguments: JSONValue,
) async throws -> JSONValue {
  let id = SessionID(session)
  let executor = sessionToolExecutor(
    space: harness.space, hub: harness.hub, credentials: harness.credentials,
    scripts: harness.runtime.scripts, control: sessionControl { harness.runtime.service },
  )
  let state = harness.toolStates.values.withLock { $0[id] ?? ToolExecutionState() }
  let callID = UUID().uuidString.lowercased()
  let payload = try await executor.execute(session: id, call: ToolCall(id: callID, name: tool, arguments: ToolArguments(arguments)), state: state)
  let context = try await harness.store.scopeContext(id, toolCallID: ToolCallID(callID))
  harness.toolStates.values.withLock {
    var state = $0[id] ?? ToolExecutionState()
    state.apply(payload)
    state.folderRoots.merge(context?.folders ?? [:]) { $1 }
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

let testImagePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==")!
let testImageModels = #"""
{
  "codex": {
    "dialect": "codex",
    "baseURL": "https://chatgpt.com/backend-api/codex",
    "models": {
      "gpt-5.6-sol": {"maxInput": 100000, "maxOutput": 10000, "efforts": ["high"], "defaultEffort": "high"}
    }
  }
}
"""#
