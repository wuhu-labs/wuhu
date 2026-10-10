#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import JSONValue
import MachineContract
import OrderedCollections
import Serve
import ServeRouting
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import SystemFiles
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

let sessionRefusalMessage = "not available to a session"

// The session a request's exec token stands for, and the group it acts in,
// for the length of that request.
enum SessionPrincipal {
  @TaskLocal static var current: GatedSession?
}

struct GatedSession: Hashable, Sendable {
  let session: SessionID
  let group: GroupID
}

// Every request whose bearer is an exec token acts as that exec's session, on
// the verbs a session has and under the rules its own tools keep; nothing else
// reaches the rest of the API with one. Requests without one pass to
// `otherwise` untouched.
func sessionGate(
  space: Space,
  hub: MachineHub,
  runtime: SessionRuntime,
  tokens: ExecTokens,
  credentials: CredentialResolver,
  routed: @escaping UpgradingHandler,
  otherwise: @escaping UpgradingHandler,
) -> UpgradingHandler {
  let gated = sessionRouter(space: space, hub: hub, runtime: runtime, credentials: credentials, routed: routed).upgradingHandler
  @Dependency(\.date) var dateGen
  return { request in
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer " + ExecTokens.prefix) else {
      return try await otherwise(request)
    }
    switch await sessionVerdict(String(header.dropFirst("Bearer ".count)), tokens: tokens, space: space, now: dateGen.now) {
    case let .refused(response):
      return .response(response)
    case let .session(holder):
      // An exec token acts in its session's group; naming another is refused
      // here, whatever the route.
      if let refused = groupMismatch(request, session: holder.session, group: holder.group) {
        return .response(refused)
      }
      return try await SessionPrincipal.$current.withValue(holder) {
        try await gated(request)
      }
    }
  }
}

enum SessionVerdict {
  case session(GatedSession)
  case refused(Response)
}

// Only a state the exec never comes back from ends its token. Machine-lost is
// not one: the exec resumes when its machine reconnects (and a real exit then
// settles the row), so the token keeps working meanwhile.
func execHasEnded(_ terminal: ExecTerminalState?) -> Bool {
  switch terminal {
  case nil, .machineLost: false
  case .exited, .signaled, .cancelled, .reaped: true
  }
}

func sessionVerdict(_ bearer: String, tokens: ExecTokens, space: Space, now: Date) async -> SessionVerdict {
  guard let holder = tokens.holder(ofBearer: bearer, now: now) else {
    return .refused(errorResponse(
      .unauthorized,
      code: "unauthorized",
      message: "this session token is not valid: its exec has ended or passed its timeout, or the server restarted since it started",
    ))
  }
  guard let exec = try? await space.execRecord(holder.exec), !execHasEnded(exec.terminal) else {
    tokens.revoke(holder.exec)
    return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "this session token's exec \(holder.exec.rawValue) has ended"))
  }
  guard let record = try? await space.sessions.record(holder.session),
        let group = try? await space.principal(of: holder.session).group
  else {
    return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "unknown session: \(holder.session.rawValue)"))
  }
  guard case .live = record.lifecycle else {
    return .refused(errorResponse(
      .forbidden,
      code: "forbidden",
      message: "session \(holder.session.rawValue) is archived and may no longer act",
    ))
  }
  return .session(GatedSession(session: holder.session, group: group))
}

private func principal() -> GatedSession {
  guard let holder = SessionPrincipal.current else {
    preconditionFailure("a session route ran outside the session gate")
  }
  return holder
}

private func notForSessions() -> Response {
  errorResponse(.forbidden, code: "forbidden", message: sessionRefusalMessage)
}

private func sessionRouter(
  space: Space,
  hub: MachineHub,
  runtime: SessionRuntime,
  credentials: CredentialResolver,
  routed: @escaping UpgradingHandler,
) -> Router {
  let store = space.sessions
  let machines = machineSeam(hub: hub)
  let executor = sessionToolExecutor(
    space: space, hub: hub, credentials: credentials, scripts: runtime.scripts,
    control: sessionControl { runtime.service },
  )
  @Dependency(\.uuid) var uuid
  let forward: RouteHandler = { request, _ in
    switch try await routed(request) {
    case let .response(response): response
    case .webSocket: notForSessions()
    }
  }
  let tool: @Sendable (_ name: String, _ arguments: JSONValue) async throws -> ToolResultPayload = { name, arguments in
    try await executor.execute(
      session: principal().session,
      call: ToolCall(id: "wst_\(uuid().uuidString.lowercased())", name: name, arguments: ToolArguments(arguments)),
      state: ToolExecutionState(),
    )
  }

  var router = Router()
  for method in [Fetch.Method.get, .post, .put, .patch, .delete] {
    router.on(method, "/*") { _, _ in notForSessions() }
  }
  router.webSocket("/*") { _, _ in .response(notForSessions()) }

  router.get("/v1/server", use: forward)
  router.get("/v1/context", use: forward)
  router.get("/v1/identity", use: forward)
  router.get("/v1/identity/issuer-for", use: forward)
  router.get("/v1/session-tools", use: forward)
  router.get("/v1/capabilities/:kind", use: forward)
  router.get("/v1/transcribe", use: forward)
  router.post("/v1/transcribe", use: forward)
  router.post("/v1/web-search", use: forward)
  router.post("/v1/image", use: forward)
  router.get("/v1/groups", use: forward)
  router.get("/v1/machine", use: forward)
  router.get("/v1/f/*", use: forward)
  router.put("/v1/f/*") { request, parameters in
    if let address = fileRouteAddress(request.url), let refused = await foreignHomeRefusal([address], space: space) {
      return refused
    }
    return try await forward(request, parameters)
  }
  router.get("/v1/observe") { request, _ in
    await observeResponse(space: space, url: request.url, principal: Principal(actor: .session(principal().session), group: principal().group))
  }

  router.post("/v1/tools/:name") { request, parameters in
    let name = parameters["name"] ?? ""
    guard let spaceTool = SpaceToolbox.all.first(where: { $0.name == name }) else {
      return errorResponse(.notFound, code: "notFound", message: "unknown tool: \(name)")
    }
    guard let fields = sessionToolFields[name] else { return notForSessions() }
    let body = try await request.body?.text() ?? ""
    guard let input = JSONValue.parse(body) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "request body is not valid JSON")
    }
    if let refused = await foreignHomeRefusal(writtenAddresses(name, input, fields: fields), space: space) {
      return refused
    }
    do {
      let context = SpaceToolContext(
        space: space, machines: machines, principal: Principal(actor: .session(principal().session), group: principal().group),
      )
      return jsonResponse(try await spaceTool.run(context, input: input))
    } catch let error as ToolRunError {
      switch error {
      case .undecodableInput:
        return jsonResponse(error.payload, status: .badRequest)
      case .failed:
        return jsonResponse(error.payload, status: .unprocessableContent)
      }
    }
  }

  router.post("/v1/exec") { request, _ in
    let input = try await request.json(ExecMintInput.self)
    do {
      guard try await space.resolveMachine(input.machine.rawValue, usableFrom: principal().group) != nil else {
        return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
      }
      let record = try await space.mintExec(machine: input.machine, caller: principal().session.rawValue)
      await hub.noteMinted(record)
      return try Response.json(ExecMintOutput(id: record.id))
    } catch is SpaceError {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
  }
  router.get("/v1/exec") { _, _ in
    let context = SpaceToolContext(space: space, principal: Principal(actor: .session(principal().session), group: principal().group))
    return try Response.json(try await context.ownExecs())
  }
  router.get("/v1/exec/:id") { request, parameters in
    guard await ownsExec(parameters, space: space) else { return unknownExec(parameters) }
    return try await forward(request, parameters)
  }
  router.post("/v1/exec/:id/kill") { request, parameters in
    guard await ownsExec(parameters, space: space) else { return unknownExec(parameters) }
    return try await forward(request, parameters)
  }
  router.webSocket("/v1/exec/:id") { request, parameters in
    guard await ownsExec(parameters, space: space) else { return .response(unknownExec(parameters)) }
    return try await routed(request)
  }

  router.post("/v1/session") { request, _ in
    let input: SessionCreateInput
    do {
      input = try await request.json(SessionCreateInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-create body: \(error)")
    }
    var arguments: OrderedDictionary<String, JSONValue> = ["title": .string(input.title)]
    arguments["kind"] = input.kind.map { .string($0.rawValue) }
    arguments["top_level"] = input.topLevel.map(JSONValue.bool)
    arguments["group"] = input.group.map(JSONValue.string)
    arguments["executor"] = input.executor.map(JSONValue.string)
    arguments["provider"] = input.provider.map(JSONValue.string)
    arguments["model"] = input.model.map(JSONValue.string)
    arguments["effort"] = input.effort.map(JSONValue.string)
    arguments["template"] = input.template.map(JSONValue.string)
    arguments["tags"] = input.tags.map { .array($0.map(JSONValue.string)) }
    if input.topLevel == true, let named = input.group {
      do {
        let creator = try await store.record(principal().session).group
        _ = try await space.homeGroup(GroupID(rawValue: named), creator: creator)
      } catch SpaceError.groupForbidden(let named) {
        return errorResponse(.forbidden, code: "groupForbidden", message: "group \(named) is not readable from here")
      }
    }
    let payload = try await tool("create_session", .object(arguments))
    guard case let .createSession(created) = payload else { return toolRefusal(payload) }
    do {
      let record = try await store.record(created.sessionID)
      let (model, effort): (String?, String?) = switch record.executor {
      case .kernel(let specifier), .claudeCode(let specifier): (specifier.model, specifier.effort)
      case .contractor: (nil, nil)
      }
      return try Response.json(SessionCreateOutput(
        id: record.id.rawValue,
        executor: record.executor.kind,
        model: model,
        effort: effort,
        kind: record.kind == .agent ? .agent : .task,
        parent: record.parent?.rawValue,
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.post("/v1/session/:id/request") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    let input: SessionRequestInput
    do {
      input = try await request.json(SessionRequestInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-request body: \(error)")
    }
    var arguments: OrderedDictionary<String, JSONValue> = ["task": .string(id.rawValue), "message": .string(input.message)]
    arguments["deadline_seconds"] = input.deadlineSeconds.map(JSONValue.number)
    let payload = try await tool("request", .object(arguments))
    guard case let .request(opened) = payload else { return toolRefusal(payload) }
    return try Response.json(SessionRequestOutput(
      requestId: opened.requestID.rawValue,
      conversationId: opened.conversationID.rawValue,
    ))
  }

  for verb in ["interrupt", "resume", "archive", "unarchive", "tags"] {
    router.post("/v1/session/:id/\(verb)") { request, parameters in
      guard let id = sessionID(parameters) else { return unknownSession(parameters) }
      do {
        if verb == "archive" || verb == "unarchive" {
          try await store.refuseArchiving(id, by: .session(principal().session))
        } else {
          try await store.refuseControl(of: id, by: principal().session)
        }
      } catch {
        return sessionErrorResponse(error)
      }
      return try await forward(request, parameters)
    }
  }

  router.post("/v1/conversation/message") { request, _ in
    let contentType = request.headers[.contentType] ?? request.body?.contentType ?? ""
    guard MultipartReader.boundary(of: contentType) == nil else {
      return errorResponse(
        .badRequest,
        code: "invalidArgument",
        message: "a session's exec uploads no files; name space files in attachments instead",
      )
    }
    let input: ConversationPostInput
    let body: JSONValue
    do {
      body = try await request.json(JSONValue.self, upTo: maximumPostFieldsBytes)
      input = try JSONValueDecoder().decode(ConversationPostInput.self, from: body)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a conversation-post body: \(error)")
    }
    var arguments: OrderedDictionary<String, JSONValue> = ["message": .string(input.message)]
    arguments["conversation"] = input.conversation.map(JSONValue.string)
    arguments["session"] = input.session.map(JSONValue.string)
    if case let .object(fields) = body {
      arguments["user"] = fields["user"]
    }
    arguments["reply_target"] = input.replyTarget.map(JSONValue.string)
    arguments["attachments"] = input.attachments.map { .array($0.map(JSONValue.string)) }
    let payload = try await tool("send_message", .object(arguments))
    guard case let .sendMessage(sent) = payload else { return toolRefusal(payload) }
    return try Response.json(ConversationPostOutput(
      messageId: sent.messageID.rawValue,
      conversationId: sent.conversationID.rawValue,
      n: Int(sent.n),
      delivered: [],
    ))
  }
  return router
}

// The file tools a session has, each with the argument fields that name what it
// changes; a read names nothing to check.
private let sessionToolFields: [String: [String]] = [
  "read": [], "ls": [], "stat": [], "grep": [], "find": [], "history": [], "query": [],
  "write": ["path"], "edit": ["path"], "rm": ["path"], "mv": ["from", "to"], "checkout": ["path"],
  "table.schema": [], "table.create": ["path"], "table.alter": ["path"], "table.mutate": ["path"], "new": ["in"],
  "attributes.read": [], "attributes.patch": ["path"],
]

// `new` writes into `in`, or next to its template when there is none; the
// template itself is only read.
private func writtenAddresses(_ name: String, _ input: JSONValue, fields: [String]) -> [String] {
  guard case let .object(arguments) = input else { return [] }
  let named = fields.compactMap { if case let .string(address)? = arguments[$0] { address } else { nil } }
  if name == "new", named.isEmpty, case let .string(template)? = arguments["template"] {
    return [template]
  }
  return named
}

// A session's own write tool keeps it out of every other session's home; the
// same rule holds for what its exec changes.
private func foreignHomeRefusal(_ addresses: [String], space: Space) async -> Response? {
  let (session, home) = (principal().session, principal().group)
  let view = await space.fs(home)
  let resolver = FSResolver(
    space: view, spaceAt: { _ in view }, machine: { _ in view }, system: SystemFiles.vfs, group: { _, _ in view },
  )
  for address in addresses {
    guard let resolved = try? resolver.resolve(address), resolved.machine == nil, !resolved.system,
          let path = try? SpacePath(validating: resolved.path)
    else { continue }
    do {
      try SessionHome.refuseForeignWrite(
        to: path, in: resolved.group.map(GroupID.init(rawValue:)) ?? home, by: session, home: home,
      )
    } catch {
      return jsonResponse(Wire.failure(error).payload, status: .unprocessableContent)
    }
  }
  return nil
}

private func ownsExec(_ parameters: RouteParameters, space: Space) async -> Bool {
  guard let raw = parameters["id"], ExecID.isValid(raw),
        let _ = try? await SpaceToolContext(space: space, principal: Principal(actor: .session(principal().session), group: principal().group)).ownExecStatus(raw)
  else { return false }
  return true
}

private func toolRefusal(_ payload: ToolResultPayload) -> Response {
  let message = if case let .failure(failure) = payload { failure.message } else { "unexpected tool result" }
  let code = if case let .failure(failure) = payload { failure.code ?? "refused" } else { "refused" }
  return errorResponse(.unprocessableContent, code: code, message: message)
}
