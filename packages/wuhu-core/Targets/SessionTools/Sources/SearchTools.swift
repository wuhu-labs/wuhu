import enum FileSearch.SearchLimits
import JSONValue
import enum MainHub.Addressing
import func MainHub.jsonObject
import func MainHub.renderedQuery
import SessionDomain
import struct SpaceContract.FindOutput
import struct SpaceContract.GrepOutput
import struct SpaceContract.SearchSkipped
import enum SpaceContract.SearchSkipReason

// grep, find and query are main's `/v1/tools/*` verbs called as the session;
// the worker only shapes their arguments and renders their output.
extension ToolExecutor {
  func grep(_ session: SessionID, _ arguments: GrepArguments) async throws -> ToolResultPayload {
    let path = arguments.path ?? "/"
    try Addressing.refuseRelative(path)
    let output: GrepOutput = try await client(session).tool("grep", jsonObject([
      ("pattern", .string(arguments.pattern)),
      ("path", .string(path)),
      ("matchLimit", arguments.matchLimit.map(JSONValue.integer)),
      ("hidden", arguments.hidden.map(JSONValue.bool)),
      ("noIgnore", arguments.noIgnore.map(JSONValue.bool)),
      ("step", arguments.step.map(JSONValue.string)),
    ]))
    var lines = output.matches.map { "\($0.path):\($0.line): \($0.text)" }
    if lines.isEmpty { lines.append("no matches") }
    lines += searchFooter(skipped: output.skipped, cursor: output.cursor)
    return .grep(.init(output: lines.joined(separator: "\n")))
  }

  func find(_ session: SessionID, _ arguments: FindArguments) async throws -> ToolResultPayload {
    let path = arguments.path ?? "/"
    try Addressing.refuseRelative(path)
    let output: FindOutput = try await client(session).tool("find", jsonObject([
      ("glob", .string(arguments.glob)),
      ("path", .string(path)),
      ("matchLimit", arguments.matchLimit.map(JSONValue.integer)),
      ("hidden", arguments.hidden.map(JSONValue.bool)),
      ("noIgnore", arguments.noIgnore.map(JSONValue.bool)),
      ("step", arguments.step.map(JSONValue.string)),
    ]))
    var lines = output.paths
    if lines.isEmpty { lines.append("no matches") }
    lines += searchFooter(skipped: output.skipped, cursor: output.cursor)
    return .find(.init(output: lines.joined(separator: "\n")))
  }

  func query(_ session: SessionID, _ arguments: QueryArguments) async throws -> ToolResultPayload {
    let output: JSONValue = try await client(session).tool("query", .object(["sql": .string(arguments.sql)]))
    return .query(.init(output: renderedQuery(output)))
  }
}

/// What the page passed over, one line per reason, then the step to resume.
private func searchFooter(skipped: [SearchSkipped], cursor: String?) -> [String] {
  var lines = skipped.map { "skipped \($0.count) \(phrase($0.reason)), e.g. \($0.example)" }
  if let cursor {
    lines.append("more results available; pass step: \"\(cursor)\" to continue")
  }
  return lines
}

private func phrase(_ reason: SearchSkipReason) -> String {
  switch reason {
  case .hidden: "hidden (pass hidden: true to include)"
  case .ignored: "ignored by .gitignore (pass no_ignore: true to include)"
  case .binary: "binary"
  case .longLine: "with a line over \(SearchLimits.lineBytes >> 10) KiB"
  case .unreadable: "unreadable"
  }
}
