#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import JSONValue
import Serve
import ServeRouting
import SessionDomain
import SessionTools
import enum SpaceContract.SessionToolExecutor
import SpaceCore
import Synchronization
import enum WuhuAI.Tool
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

let mcpLatestProtocolVersion = "2025-06-18"
private let mcpProtocolVersions: Set<String> = [mcpLatestProtocolVersion, "2025-03-26", "2024-11-05"]

func addMcpRoutes(
  _ router: inout Router,
  space: Space,
  hub: MachineHub,
  credentials: CredentialResolver,
  version: String,
  dev: Bool,
  scripts: Scripts?,
  control: SessionControl?,
) {
  @Dependency(\.date) var dateGen
  addMcpRoutes(
    &router, space: space, hub: hub, credentials: credentials, version: version, scripts: scripts, control: control,
  ) { request, session in
    try await sessionActingRefusal(request: request, space: space, session: session, dev: dev, now: dateGen.now)
  }
}

func addMcpRoutes(
  _ router: inout Router,
  space: Space,
  hub: MachineHub,
  credentials: CredentialResolver,
  version: String,
  recordsReceipts: Bool = false,
  scripts: Scripts?,
  control: SessionControl?,
  refusal: @escaping @Sendable (Request, SessionID) async throws -> Response?,
) {
  let executor = sessionToolExecutor(
    space: space, hub: hub, credentials: credentials, scripts: scripts, control: control,
  )
  // Read-before-write is the file tools' safety rule, so the executor state
  // has to outlive one stateless JSON-RPC request. It lives for this process
  // only: a restarted server asks the caller to re-read, exactly as a
  // compacted kernel session does.
  // Keyed by generation: a read the wiped generation earned is no proof the
  // fresh one read anything.
  let states = Mutex<[SessionID: (generation: Int, state: ToolExecutionState)]>([:])
  @Dependency(\.date) var dateGen
  @Dependency(\.uuid) var uuid

  router.get("/v1/session/:id/mcp") { _, _ in
    var headers = Headers()
    headers[.allow] = "DELETE, POST"
    return Response(status: .methodNotAllowed, headers: headers)
  }

  router.delete("/v1/session/:id/mcp") { _, _ in
    Response(status: .noContent)
  }

  router.post("/v1/session/:id/mcp") { request, parameters in
    guard let session = sessionID(parameters) else { return unknownSession(parameters) }
    let body = try await request.body?.text() ?? ""
    guard let message = JSONValue.parse(body) else {
      return rpcFailure(.null, code: -32700, "request body is not valid JSON", status: .badRequest)
    }
    if case .array = message {
      return rpcFailure(
        .null, code: -32600,
        "JSON-RPC batching was removed in MCP revision 2025-06-18; send one message per request",
        status: .badRequest,
      )
    }
    guard case let .object(fields) = message else {
      return rpcFailure(.null, code: -32600, "expected a JSON-RPC message object", status: .badRequest)
    }
    // A notification carries no id and takes no response, initialized included.
    guard let callID = fields["id"], callID != .null else {
      return Response(status: .accepted)
    }
    guard case let .string(method)? = fields["method"] else {
      return rpcFailure(callID, code: -32600, "missing JSON-RPC method", status: .badRequest)
    }
    if let refused = try await refusal(request, session) {
      return refused
    }
    let params: JSONValue = fields["params"] ?? .object([:])
    switch method {
    case "initialize":
      let requested: String? = if case let .string(raw)? = params.field("protocolVersion") { raw } else { nil }
      let negotiated = requested.flatMap { mcpProtocolVersions.contains($0) ? $0 : nil } ?? mcpLatestProtocolVersion
      return rpcResult(callID, .object([
        "protocolVersion": .string(negotiated),
        "capabilities": .object(["tools": .object([:])]),
        "serverInfo": .object(["name": .string("wuhu"), "version": .string(version)]),
      ]))
    case "ping":
      return rpcResult(callID, .object([:]))
    case "tools/list":
      return rpcResult(callID, .object(["tools": .array(SessionToolExecutor.claudeCode.tools.map(mcpToolDescriptor))]))
    case "tools/call":
      guard case let .string(name)? = params.field("name") else {
        return rpcFailure(callID, code: -32602, "tools/call wants a params.name string")
      }
      let arguments = params.field("arguments") ?? .object([:])
      guard case .object = arguments else {
        return rpcFailure(callID, code: -32602, "tools/call arguments must be an object")
      }
      guard SessionToolExecutor.claudeCode.tools.contains(where: {
        guard case let .function(toolName, _, _) = $0 else { return false }
        return toolName == name
      }) else {
        return rpcFailure(callID, code: -32602, "unknown tool: \(name)")
      }
      // Claude Code names the tool call it is making; keyed by that id, a call
      // it repeats replays its recorded outcome instead of running twice.
      let toolCallID = params.field("_meta")?.field("claudecode/toolUseId").flatMap(\.stringValue)
        ?? "mcp_\(uuid().uuidString.lowercased())"
      let call = ToolCall(id: toolCallID, name: name, arguments: ToolArguments(arguments))
      let generation: Int
      do {
        generation = try await space.sessions.generationState(session).generation
      } catch {
        return sessionErrorResponse(error)
      }
      let payload = try await executor.execute(
        session: session,
        call: call,
        state: states.withLock { held(session, generation: generation, in: &$0) },
      ).clamped()
      // A Claude Code session's environment is folded from these: every
      // effect its tools had, keyed by the tool call id its log names.
      if recordsReceipts, !payload.isToolFailure {
        try await space.sessions.recordReceipt(session, toolCallID: ToolCallID(toolCallID), payload: payload)
      }
      let context = try await space.sessions.scopeContext(session, toolCallID: ToolCallID(toolCallID))
      states.withLock {
        var state = held(session, generation: generation, in: &$0)
        state.apply(payload)
        state.folderRoots.merge(context?.folders ?? [:]) { $1 }
        $0[session] = (generation, state)
      }
      return rpcResult(callID, .object([
        "content": .array(await mcpContent(payload, space: space)),
        "isError": .bool(payload.isToolFailure),
      ]))
    default:
      return rpcFailure(callID, code: -32601, "unknown method: \(method)")
    }
  }
}

// Acting as a session from outside needs a human admin of the session's
// group, which behind --dev is the anonymous seat.
func sessionActingRefusal(
  request: Request,
  space: Space,
  session: SessionID,
  dev: Bool,
  now: Date,
) async throws -> Response? {
  let actor: ManagementActor
  switch try await managementVerdict(request: request, space: space, dev: dev, now: now) {
  case let .refused(response):
    return response
  case let .actor(resolved):
    actor = resolved
  }
  let record: SessionRecord
  do {
    record = try await space.sessions.record(session)
  } catch {
    // A seat admin of no group learns nothing about which sessions exist.
    return actor.isAdmin ? sessionErrorResponse(error) : adminRequired("acting as a session over MCP")
  }
  if let account = actor.accountID, try await !space.isHumanAdmin(account, of: record.group) {
    return adminRequired("acting as a session of group \(record.group.rawValue) over MCP")
  }
  guard case .live = record.lifecycle else {
    return errorResponse(
      .conflict,
      code: "archivedSession",
      message: "session \(session.rawValue) is archived and cannot act",
    )
  }
  return nil
}

private func mcpToolDescriptor(_ tool: Tool) -> JSONValue {
  guard case let .function(name, description, parameters) = tool else {
    preconditionFailure("MCP cannot expose provider-hosted tools")
  }
  return .object([
    "name": .string(name),
    "description": .string(description),
    "inputSchema": parameters,
    "_meta": .object(["anthropic/maxResultSizeChars": .integer(claudeCodeResultChars)]),
  ])
}

// Claude Code swaps a tool result past 50,000 characters for a 2 KB preview
// and a file unless the tool asks for more, up to 500,000; the kernel's own
// cut stays the ceiling of what one result carries.
let claudeCodeResultChars = 500_000

private func mcpContent(_ payload: ToolResultPayload, space: Space) async -> [JSONValue] {
  let text: JSONValue = .object(["type": .string("text"), "text": .string(payload.renderedText)])
  guard case let .read(read) = payload, let image = read.image,
        let data = try? await space.imageBytes(image)
  else { return [text] }
  return switch ImageFitting.fit(data, mimeType: image.mimeType, limits: .claude) {
  case let .image(fitted, mimeType):
    [text, .object([
      "type": .string("image"),
      "data": .string(fitted.base64EncodedString()),
      "mimeType": .string(mimeType),
    ])]
  case let .note(note):
    [text, .object(["type": .string("text"), "text": .string(note)])]
  }
}

private func rpcResult(_ id: JSONValue, _ result: JSONValue) -> Response {
  jsonResponse(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
}

private func rpcFailure(
  _ id: JSONValue,
  code: Int,
  _ message: String,
  status: Status = .ok,
) -> Response {
  jsonResponse(
    .object([
      "jsonrpc": .string("2.0"),
      "id": id,
      "error": .object(["code": .integer(code), "message": .string(message)]),
    ]),
    status: status,
  )
}

extension JSONValue {
  fileprivate func field(_ name: String) -> JSONValue? {
    guard case let .object(fields) = self else { return nil }
    return fields[name]
  }
}

extension ToolResultPayload {
  fileprivate var isToolFailure: Bool {
    if case .failure = self { return true }
    return false
  }
}

private func held(
  _ session: SessionID,
  generation: Int,
  in states: inout [SessionID: (generation: Int, state: ToolExecutionState)],
) -> ToolExecutionState {
  guard let entry = states[session], entry.generation == generation else { return ToolExecutionState() }
  return entry.state
}
