import Dependencies
import JSONValue
import struct MachineContract.ExecID
import struct MainHub.CancelArguments
import enum MainHub.CancelTarget
import enum MainHub.RosterTool
import struct MainHub.ToolProblem
import SessionDomain
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

extension ToolExecutor {
  func cancel(_ session: SessionID, _ arguments: CancelArguments, call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload {
    switch try CancelTarget(arguments.id) {
    case .subscription: try await cancelSubscription(session, call.id, arguments.id)
    case .exec: try await owner.execute(session: session, call: call, state: state)
    case let .script(script): try await stopScript(session, script)
    }
  }

  // wuhu:session's cancel: the tool, from a script, outside any transcript.
  func cancel(_ session: SessionID, id: String) async throws -> ToolResultPayload {
    @Dependency(\.uuid) var uuid
    let call = ToolCall(id: "script:\(uuid().uuidString.lowercased())", name: RosterTool.cancel.rawValue, arguments: ToolArguments(.object(["id": .string(id)])))
    return try await execute(session: session, call: call, state: ToolExecutionState()).payload
  }

  func stopScript(_ session: SessionID, _ script: String) async throws -> ToolResultPayload {
    guard let scripts else { throw ToolProblem("cancel: scripts are not available here") }
    return try await scripts.stop(script, session: session)
  }
}
