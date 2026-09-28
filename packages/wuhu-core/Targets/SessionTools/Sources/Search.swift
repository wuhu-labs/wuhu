import JSONValue
import OrderedCollections
import SessionDomain
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

extension ToolExecutor {
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
      ("entryLimit", arguments.entryLimit.map(JSONValue.integer)),
      ("step", arguments.step.map(JSONValue.string)),
    ])
    let output = try await grepTool.run(SpaceToolContext(space: space, machines: machines, principal: try await space.principal(of: session)), input: input)
    guard case let .object(fields) = output, case let .array(matches)? = fields["matches"] else {
      throw ToolProblem("grep returned an unexpected result shape")
    }
    var lines: [String] = matches.compactMap { match in
      guard case let .object(entry) = match,
            case let .string(path)? = entry["path"],
            case let .integer(line)? = entry["line"],
            case let .string(text)? = entry["text"]
      else { return nil }
      return "\(path):\(line): \(ToolOutput.clampedLine(text))"
    }
    if lines.isEmpty { lines.append("no matches") }
    if case let .string(cursor)? = fields["cursor"] {
      lines.append("more results available; pass step: \"\(cursor)\" to continue")
    }
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
      ("entryLimit", arguments.entryLimit.map(JSONValue.integer)),
      ("step", arguments.step.map(JSONValue.string)),
    ])
    let output = try await findTool.run(SpaceToolContext(space: space, machines: machines, principal: try await space.principal(of: session)), input: input)
    guard case let .object(fields) = output, case let .array(paths)? = fields["paths"] else {
      throw ToolProblem("find returned an unexpected result shape")
    }
    var lines: [String] = paths.compactMap { path in
      guard case let .string(found) = path else { return nil }
      return found
    }
    if lines.isEmpty { lines.append("no matches") }
    if case let .string(cursor)? = fields["cursor"] {
      lines.append("more results available; pass step: \"\(cursor)\" to continue")
    }
    try await deliverContext(session, callID, touching: address, state: state)
    return .find(.init(output: lines.joined(separator: "\n")))
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
