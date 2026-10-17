import Dependencies
import JSONValue
import struct MachineContract.ExecID
import SessionDomain
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

// cancel(id): the id's prefix says what it names. Subscriptions are cancelled
// by the owner, which holds their slots, and so are exec jobs; a script where
// it runs.
enum CancelTarget: Equatable {
  case subscription
  case script(String)
  case exec(ExecID)

  static let subscriptionPrefixes = ["obs.", "timer.", "stall.", "deadline."]

  init(_ id: String) throws(ToolProblem) {
    if id.hasPrefix("script.") {
      let script = String(id.dropFirst("script.".count))
      guard !script.isEmpty else { throw ToolProblem("cancel: \(id) names no script", code: "invalidArgument") }
      self = .script(script)
      return
    }
    if id.hasPrefix("exec.") {
      let exec = String(id.dropFirst("exec.".count))
      guard !exec.isEmpty else { throw ToolProblem("cancel: \(id) names no exec", code: "invalidArgument") }
      self = .exec(ExecID(rawValue: exec))
      return
    }
    if Self.subscriptionPrefixes.contains(where: id.hasPrefix) {
      self = .subscription
      return
    }
    if id.count == 8, id.allSatisfy(\.isHexDigit) {
      throw ToolProblem("cancel: a script id is written script.\(id)", code: "invalidArgument")
    }
    throw ToolProblem("cancel: \(id) is not an id cancel takes; ids start with obs., timer., script. or exec.", code: "invalidArgument")
  }
}

extension ToolExecutor {
  func cancel(_ session: SessionID, _ arguments: CancelArguments, call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload {
    switch try CancelTarget(arguments.id) {
    case .subscription, .exec: try await owner.execute(session: session, call: call, state: state)
    case let .script(script): try await stopScript(session, script)
    }
  }

  // wuhu:session's cancel: the tool, from a script, outside any transcript.
  func cancel(_ session: SessionID, id: String) async throws -> ToolResultPayload {
    @Dependency(\.uuid) var uuid
    let call = ToolCall(id: "script:\(uuid().uuidString.lowercased())", name: RosterTool.cancel.rawValue, arguments: ToolArguments(.object(["id": .string(id)])))
    return try await execute(session: session, call: call, state: ToolExecutionState())
  }

  func stopScript(_ session: SessionID, _ script: String) async throws -> ToolResultPayload {
    guard let scripts else { throw ToolProblem("cancel: scripts are not available here") }
    return try await scripts.stop(script, session: session)
  }
}
