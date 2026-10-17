import enum FileSearch.SearchLimits
import JSONValue
import OrderedCollections
import SessionDomain
import struct SpaceContract.FindOutput
import struct SpaceContract.GrepOutput
import struct SpaceContract.SearchSkipped
import enum SpaceContract.SearchSkipReason
import SpaceCore
import SpaceTools

private let grepTool = SpaceToolbox.all.first { $0.name == "grep" }!
private let findTool = SpaceToolbox.all.first { $0.name == "find" }!

func jsonObject(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var fields: OrderedDictionary<String, JSONValue> = [:]
  for (name, value) in pairs {
    if let value { fields[name] = value }
  }
  return .object(fields)
}

extension InProcessToolOwnerClient {
  func grep(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: GrepArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let address = try await resolve(arguments.path ?? "/", as: session)
    let input = jsonObject([
      ("pattern", .string(arguments.pattern)),
      ("path", .string(address.rendered)),
      ("matchLimit", arguments.matchLimit.map(JSONValue.integer)),
      ("hidden", arguments.hidden.map(JSONValue.bool)),
      ("noIgnore", arguments.noIgnore.map(JSONValue.bool)),
      ("step", arguments.step.map(JSONValue.string)),
    ])
    let output = try await searchOutput(GrepOutput.self, grepTool, input, session)
    var lines = output.matches.map { "\($0.path):\($0.line): \($0.text)" }
    if lines.isEmpty { lines.append("no matches") }
    lines += searchFooter(skipped: output.skipped, cursor: output.cursor)
    try await deliverContext(session, callID, touching: address, state: state)
    return .grep(.init(output: lines.joined(separator: "\n")))
  }

  func find(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: FindArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let address = try await resolve(arguments.path ?? "/", as: session)
    let input = jsonObject([
      ("glob", .string(arguments.glob)),
      ("path", .string(address.rendered)),
      ("matchLimit", arguments.matchLimit.map(JSONValue.integer)),
      ("hidden", arguments.hidden.map(JSONValue.bool)),
      ("noIgnore", arguments.noIgnore.map(JSONValue.bool)),
      ("step", arguments.step.map(JSONValue.string)),
    ])
    let output = try await searchOutput(FindOutput.self, findTool, input, session)
    var lines = output.paths
    if lines.isEmpty { lines.append("no matches") }
    lines += searchFooter(skipped: output.skipped, cursor: output.cursor)
    try await deliverContext(session, callID, touching: address, state: state)
    return .find(.init(output: lines.joined(separator: "\n")))
  }

  private func searchOutput<Output: Decodable>(
    _: Output.Type, _ tool: SpaceTool, _ input: JSONValue, _ session: SessionID,
  ) async throws -> Output {
    let context = SpaceToolContext(space: space, machines: machines, principal: try await space.principal(of: session))
    return try JSONValueDecoder().decode(Output.self, from: try await tool.run(context, input: input))
  }

  /// What the page passed over, one line per reason, then the step to resume.
  private func searchFooter(skipped: [SearchSkipped], cursor: String?) -> [String] {
    var lines = skipped.map { "skipped \($0.count) \(phrase($0.reason)), e.g. \($0.example)" }
    if let cursor {
      lines.append("more results available; pass step: \"\(cursor)\" to continue")
    }
    return lines
  }

  func query(_ session: SessionID, _ arguments: QueryArguments) async throws -> ToolResultPayload {
    do {
      let rows = try await space.query(arguments.sql, byteLimit: scriptBufferBytes, as: try await space.principal(of: session))
      return .query(.init(output: renderedRows(rows)))
    } catch SpaceError.queryResultTooLarge {
      throw ToolProblem("the result is over \(scriptBufferBytes >> 20) MiB; select fewer rows or columns")
    }
  }
}

let queryRowCap = 500

func renderedRows(_ rows: Rows) -> String {
  let limited = Rows(
    columns: rows.columns,
    decltypes: rows.decltypes,
    rows: Array(rows.rows.prefix(queryRowCap)),
  )
  var output = Wire.queryOutput(limited).jsonString()
  if rows.rows.count > queryRowCap {
    output += "\n(showing the first \(queryRowCap) of \(rows.rows.count) rows)"
  }
  return output
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
