#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import struct InferenceKit.InferenceMetric
import struct InferenceKit.InferenceMetricsSink
import JSONValue
import MachineContract
import struct MainHub.CancelArguments
import struct MainHub.CreateSessionArguments
import class MainHub.Hub
import struct MainHub.IncompleteSession
import struct MainHub.ManipulateUIArguments
import struct MainHub.ObserveArguments
import struct MainHub.ReportArguments
import struct MainHub.RequestArguments
import struct MainHub.SendMessageArguments
import struct MainHub.SetTitleArguments
import struct MainHub.TimerArguments
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import Serve
import ServeRouting
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import SystemFiles
import struct WuhuAI.Usage

let sessionRefusalMessage = "not available to a session"

// The session a request's exec token stands for, and the group it acts in,
// for the length of that request.
enum SessionPrincipal {
  @TaskLocal static var current: GatedSession?
}

struct GatedSession: Hashable, Sendable {
  let session: SessionID
  let group: GroupID
  /// True when the bearer is an exec's token (in the command's environment,
  /// so anything it reads can be printed), false for the worker's own.
  let exec: Bool
}

// Every request whose bearer is a session token (the worker's, for a mounted
// session, or an exec's) acts as that session, on the verbs a session has and
// under the rules its own tools keep; nothing else reaches the rest of the API
// with one. Requests without one pass to `otherwise` untouched.
func sessionGate(
  space: Space,
  hub: MachineHub,
  machines: MachineSeam,
  owner: Hub,
  tokens: ExecTokens,
  runtime: SessionRuntime,
  credentials: CredentialResolver,
  identity: IdentityController?,
  metrics: InferenceMetricsSink,
  routed: @escaping UpgradingHandler,
  otherwise: @escaping UpgradingHandler,
) -> UpgradingHandler {
  let gated = sessionRouter(space: space, hub: hub, machines: machines, owner: owner, credentials: credentials, identity: identity, metrics: metrics, routed: routed).upgradingHandler
  let workerRoutes = workerRouter(owner: owner, runtime: runtime).upgradingHandler
  @Dependency(\.date) var dateGen
  return { request in
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer " + ExecTokens.prefix) else {
      return try await otherwise(request)
    }
    switch await sessionVerdict(String(header.dropFirst("Bearer ".count)), tokens: tokens, space: space, now: dateGen.now) {
    case let .refused(response):
      return .response(response)
    case .worker:
      return try await workerRoutes(request)
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
  /// The worker's own token: the loop's routes, never a session's.
  case worker
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
  if tokens.worker(ofBearer: bearer) != nil { return .worker }
  let session: SessionID
  var boundGroup: GroupID?
  var exec = true
  if let mounted = tokens.session(ofBearer: bearer) {
    session = mounted
    exec = false
  } else if let holder = tokens.v2Holder(ofBearer: bearer) {
    guard holder.expiresAt > now else { return .refused(errorResponse(.unauthorized, code: "credentialExpired", message: "Session exec credential expired; credentials are not renewed")) }
    guard (try? await holder.active()) == true else { return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "Session exec operation ended or is unavailable")) }
    session = holder.key.session; boundGroup = holder.key.group
  } else {
    guard let holder = tokens.holder(ofBearer: bearer, now: now) else {
      return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "this session token is not valid: its exec has ended or passed its timeout, or the server restarted since it started"))
    }
    guard let exec = try? await space.execRecord(holder.exec), !execHasEnded(exec.terminal) else {
      tokens.revoke(holder.exec)
      return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "this session token's exec \(holder.exec.rawValue) has ended"))
    }
    session = holder.session
  }
  guard let record = try? await space.sessions.record(session),
        let group = try? await space.principal(of: session).group
  else {
    return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "unknown session: \(session.rawValue)"))
  }
  guard boundGroup == nil || boundGroup == group else { return .refused(errorResponse(.forbidden, code: "groupForbidden", message: "Session exec group changed")) }
  guard case .live = record.lifecycle else {
    return .refused(errorResponse(
      .forbidden,
      code: "forbidden",
      message: "session \(session.rawValue) is archived and may no longer act",
    ))
  }
  return .session(GatedSession(session: session, group: group, exec: exec))
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
  machines: MachineSeam,
  owner: Hub,
  credentials: CredentialResolver,
  identity: IdentityController?,
  metrics: InferenceMetricsSink,
  routed: @escaping UpgradingHandler,
) -> Router {
  let store = space.sessions
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date
  let forward: RouteHandler = { request, _ in
    switch try await routed(request) {
    case let .response(response): response
    case .webSocket, .boundedWebSocket: notForSessions()
    }
  }
  // The tool call a request runs for is its idempotency key: a call that
  // already ran gets its first answer again, not a second run. A request
  // without one (the CLI from an exec) runs every time. The hub's verbs own
  // this themselves, each recording its answer in the write that makes its
  // effect (or making the effect by an id derived from the call); only the
  // file tools are replayed here, from the API's recorded answer.
  let callID: @Sendable (Request) -> ToolCallID = { request in
    request.headers[ToolCallHeader.name].map(ToolCallID.init(rawValue:)) ?? ToolCallID("wst_\(uuid().uuidString.lowercased())")
  }
  // The recorded answer stands only for the request it answered: a repeat of
  // the tool call that asks something else is a conflict.
  let answeredOther: @Sendable (ToolCallID, APIReceipt) -> Response = { toolCall, receipt in
    errorResponse(.conflict, code: "conflict", message: "tool call \(toolCall.rawValue) was already answered for \(receipt.request ?? "another request")")
  }
  let receipted: @Sendable (Request, String, @Sendable () async throws -> Response) async throws -> Response = { request, identity, body in
    let toolCall = request.headers[ToolCallHeader.name].map(ToolCallID.init(rawValue:))
    if let toolCall, let receipt = try await store.apiReceipt(principal().session, toolCallID: toolCall) {
      if let recorded = receipt.request, recorded != identity { return answeredOther(toolCall, receipt) }
      return jsonResponse(JSONValue.parse(receipt.body) ?? .null, status: Status(code: receipt.status))
    }
    let response = try await body()
    guard let toolCall, 200 ..< 300 ~= response.status.code else { return response }
    let answer = String(decoding: try await response.data(), as: UTF8.self)
    try await store.recordAPIReceipt(
      principal().session, toolCallID: toolCall, APIReceipt(status: response.status.code, body: answer, request: identity),
    )
    return jsonResponse(JSONValue.parse(answer) ?? .null, status: response.status)
  }
  // A session verb runs on the hub as the session, and answers as the tool
  // would: a typed failure is a 422 carrying its code.
  let answered: @Sendable (@Sendable () async throws -> ToolResultPayload) async throws -> ToolResultPayload = { body in
    try await owner.answering(as: principal().session, body)
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
  router.post("/v1/conversation", use: forward)
  router.get("/v1/conversation/:id/messages", use: forward)
  router.get("/v1/conversation/:id/observe", use: forward)
  router.get("/v1/conversation/:id/page", use: forward)
  router.get("/v1/conversations", use: forward)
  router.get("/v1/dm", use: forward)
  for operation in ["add", "remove", "rename"] {
    router.post("/v1/channel/:id/\(operation)", use: forward)
  }
  router.get("/v1/groups", use: forward)
  router.get("/v1/templates", use: forward)
  router.get("/v1/secret", use: forward)
  // A value is for the worker's script, which masks what it got; an exec's
  // token can print whatever it reads, so it never gets one.
  router.get("/v1/secret/:name") { request, parameters in
    guard !principal().exec else {
      return errorResponse(.forbidden, code: "unauthorized", message: "a secret's value is read only by a session's script, never from an exec")
    }
    return try await forward(request, parameters)
  }
  router.put("/v1/secret/:name", use: forward)
  router.delete("/v1/secret/:name", use: forward)
  // A session's own 60-second OIDC token for `audience`, naming the session
  // and its group (no exec claims): what a script's `fetch(url, {identity:
  // true})` carries. The exec variant (an exec's `wit_` grant) lives outside
  // the gate, in addIDTokenRoute.
  router.get("/v1/id-token") { request, _ in
    guard let named = queryValues(of: request.url)["audience"], let audience = URL(string: named), fetchOrigin(audience) == named else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "audience must be an origin: scheme://host[:port], lowercase, without a path")
    }
    guard let identity else {
      return errorResponse(.serviceUnavailable, code: "fetchIdentityUnavailable", message: "The server could not sign an OIDC token.")
    }
    let now = date.now
    let lifetime = 60
    do {
      let token = try await identity.token(
        audience: audience, space: try await space.identity().rawValue, group: principal().group.rawValue, session: principal().session.rawValue,
        now: now, id: uuid(), lifetime: lifetime,
      )
      return clockReading(jsonResponse(.object(["token": .string(token), "expiresAt": .integer(Int(now.timeIntervalSince1970) + lifetime)])), now: now)
    } catch let error as IdentityError {
      return identityFailure(error)
    }
  }
  // The roster is the hub's (its refusal when the server has no machine
  // backend, its attach state); the API's shape adds each machine's group.
  router.get("/v1/machine") { _, _ in
    let payload = try await answered { try await owner.machineRoster(principal().session) }
    guard case let .machines(roster) = payload else { return toolRefusal(payload) }
    let groups = Dictionary(uniqueKeysWithValues: try await space.machines(usableFrom: principal().group).map { ($0.id.rawValue, $0.group.rawValue) })
    return try Response.json(roster.machines.compactMap { listing in
      groups[listing.id].map { MachineStatus(id: MachineID(rawValue: listing.id), name: listing.name, group: $0, attached: listing.attached) }
    })
  }
  // A directory on a machine, which only a machine has; a file's parents the
  // byte route makes itself.
  router.post("/v1/machine/:id/mkdir") { request, parameters in
    let id = MachineID(rawValue: parameters["id"] ?? "")
    guard case let .object(fields)? = JSONValue.parse(try await request.body?.text() ?? ""),
          case let .string(path)? = fields["path"], path.hasPrefix("/")
    else { return errorResponse(.badRequest, code: "invalidArgument", message: "mkdir takes an absolute path on the machine") }
    guard try await space.resolveMachine(id.rawValue, usableFrom: principal().group) != nil else {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(id.rawValue)")
    }
    switch try await MachineSeam.$caller.withValue(principal().session) { try await machines.vfs(id, .mkdir(path: path)) } {
    case .ok: return jsonResponse(.object([:]))
    case let .error(error): return jsonResponse(machineFailure(error).payload, status: .unprocessableContent)
    default: return errorResponse(.unprocessableContent, code: "internal", message: "machine returned an unexpected mkdir result for \(path)")
    }
  }
  // A machine the byte route reaches sees the session as its caller.
  router.get("/v1/f/*") { request, parameters in
    try await MachineSeam.$caller.withValue(principal().session) { try await forward(request, parameters) }
  }
  router.put("/v1/f/*") { request, parameters in
    let address = fileRouteAddress(request.url)
    if let address, let refused = await foreignHomeRefusal([address], space: space) {
      return refused
    }
    return try await receipted(request, "PUT \(address ?? request.url.path)") {
      try await MachineSeam.$caller.withValue(principal().session) { try await forward(request, parameters) }
    }
  }
  // The answer recorded for the client's tool call: a worker whose call is a
  // replay learns its write already happened before paying for what precedes it.
  router.get("/v1/receipt") { request, _ in
    guard let toolCall = request.headers[ToolCallHeader.name].map(ToolCallID.init(rawValue:)) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "a receipt is read with the \(ToolCallHeader.name) header")
    }
    guard let receipt = try await store.apiReceipt(principal().session, toolCallID: toolCall) else {
      return errorResponse(.notFound, code: "notFound", message: "no answer recorded for tool call \(toolCall.rawValue)")
    }
    // `?address=` asks for the write of that address and nothing else.
    if let address = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "address" })?.value,
       receipt.request != "PUT \(address)"
    {
      return answeredOther(toolCall, receipt)
    }
    return jsonResponse(JSONValue.parse(receipt.body) ?? .null, status: Status(code: receipt.status))
  }
  // The caller's prompt home, frozen at its prompt revision: the first read
  // fixes the revision, every later one reads the same files.
  router.get("/v1/prompt") { _, _ in
    let session = principal().session
    do {
      let home = try await space.sessionHome(session, at: try await store.activatePromptRevision(session))
      return try Response.json(SessionPromptOutput(
        home: home.path, group: home.group.rawValue,
        spaceLayer: promptScope(home.spaceLayer), groupLayer: promptScope(home.groupLayer), homeLayer: promptScope(home.home),
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }
  // Bytes a tool answer stored by hash: an image `read` delivered to the
  // transcript. Only the session whose read stored it, and only its worker:
  // an exec's token prints whatever it reads.
  router.get("/v1/blob/:hash") { _, parameters in
    guard let hash = parameters["hash"] else { return errorResponse(.badRequest, code: "invalidArgument", message: "a blob is named by its hash") }
    guard !principal().exec else {
      return errorResponse(.forbidden, code: "unauthorized", message: "a blob is read by the session's worker, never from an exec")
    }
    do {
      let bytes = Data(try await space.sessionBlobBytes(hash, for: principal().session))
      var headers = Headers()
      headers[.contentType] = "application/octet-stream"
      headers[.contentLength] = String(bytes.count)
      return Response(status: .ok, headers: headers, body: .bytes(bytes, contentType: "application/octet-stream"))
    } catch SpaceError.notFound {
      return errorResponse(.notFound, code: "notFound", message: "no blob \(hash)")
    }
  }
  // One inference the worker ran for the caller, into the server's metrics,
  // once per attempt id however often it is reported. Only the worker reports;
  // an exec's token would let any command bill its session.
  router.post("/v1/inferences") { request, _ in
    guard !principal().exec else {
      return errorResponse(.forbidden, code: "unauthorized", message: "an inference is reported by the session's worker, never from an exec")
    }
    let input = try await request.json(InferenceReportInput.self)
    guard let outcome = InferenceMetric.Outcome(rawValue: input.outcome) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "unknown inference outcome: \(input.outcome)")
    }
    let usage = input.usage.map { [$0.inputTokens, $0.outputTokens, $0.cacheReadTokens, $0.cacheWriteTokens, $0.reasoningTokens ?? 0, $0.totalTokens] } ?? []
    guard !input.id.isEmpty, input.timestamp.isFinite, ([input.durationMs, input.ttftMs ?? 0, input.status ?? 0] + usage).allSatisfy({ $0 >= 0 }) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "an inference report names its attempt and counts nothing negative")
    }
    await metrics.record(InferenceMetric(
      id: input.id, timestamp: Date(timeIntervalSince1970: input.timestamp), session: principal().session,
      provider: input.provider, model: input.model, servedModel: input.servedModel, effort: input.effort,
      outcome: outcome, errorKind: input.errorKind, status: input.status,
      ttftMs: input.ttftMs.map(Int64.init), durationMs: Int64(input.durationMs),
      usage: input.usage.map {
        Usage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheWriteTokens: $0.cacheWriteTokens, reasoningTokens: $0.reasoningTokens, totalTokens: $0.totalTokens)
      },
    ))
    return jsonResponse(.object([:]))
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
    return try await receipted(request, "POST /v1/tools/\(name)") {
      do {
        let context = SpaceToolContext(
          space: space, machines: machines, principal: Principal(actor: .session(principal().session), group: principal().group),
        )
        // A machine the tool reaches sees the session as its caller.
        let output = try await MachineSeam.$caller.withValue(principal().session) { try await spaceTool.run(context, input: input) }
        return jsonResponse(output)
      } catch let error as ToolRunError {
        switch error {
        case .undecodableInput:
          return jsonResponse(error.payload, status: .badRequest)
        case .failed:
          return jsonResponse(error.payload, status: .unprocessableContent)
        }
      }
    }
  }

  router.post("/v1/exec") { request, _ in
    let input = try await request.json(ExecMintInput.self)
    do {
      guard try await space.resolveMachine(input.machine.rawValue, usableFrom: principal().group) != nil else {
        return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
      }
      try await hub.requireExecKind(input.machine)
      let record: ExecRecord
      if let script = input.script {
        // A run_script execution's process: owned by the script, released when it ends.
        record = try await space.mintScriptExec(machine: input.machine, session: principal().session.rawValue, script: script)
        await hub.noteMinted(record)
      } else if let callID = request.headers[ToolCallHeader.name] {
        let claim = try await space.claimExec(
          machine: input.machine, caller: principal().session.rawValue,
          toolCallID: ToolCallID(rawValue: callID), spec: input.spec?.jsonString(),
        )
        record = claim.record
        if !claim.rejoined { await hub.noteMinted(record) }
      } else {
        record = try await space.mintExec(machine: input.machine, caller: principal().session.rawValue)
        await hub.noteMinted(record)
      }
      return try Response.json(ExecMintOutput(id: record.id))
    } catch let error as OperationError {
      return try Response.json(ErrorEnvelope(error), status: .unprocessableContent)
    } catch is SpaceError {
      return errorResponse(.notFound, code: "notFound", message: "unknown machine: \(input.machine.rawValue)")
    }
  }
  router.delete("/v1/script-execs/:script") { _, parameters in
    guard let script = parameters["script"], !script.isEmpty else {
      return errorResponse(.notFound, code: "notFound", message: "unknown script")
    }
    try await space.releaseScriptExecs(script: script, session: principal().session.rawValue)
    return try Response.json([String: String]())
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
    if let id = parameters["id"], let record = try await space.execRecord(ExecID(rawValue: id)), record.terminal != nil {
      return errorResponse(.unprocessableContent, code: "alreadyEnded", message: "exec has already ended")
    }
    return try await forward(request, parameters)
  }
  for (action, owed) in [("detach", true), ("delivered", false)] {
    router.post("/v1/exec/:id/\(action)") { _, parameters in
      guard let raw = parameters["id"], ExecID.isValid(raw),
            try await space.setExecEndOwed(ExecID(rawValue: raw), caller: principal().session.rawValue, owed: owed)
      else { return unknownExec(parameters) }
      return try Response.json(JSONValue.object([:]))
    }
  }
  router.webSocket("/v1/exec/:id") { request, parameters in
    guard await ownsExec(parameters, space: space) else { return .response(unknownExec(parameters)) }
    return try await routed(request)
  }

  router.post("/v1/session") { request, _ in
    // The kind reaches the hub as written: an odd one is the hub's answer, not
    // a decoding failure here.
    let input: SessionCreateInput
    let kind: String?
    do {
      var body = try await request.json(JSONValue.self, upTo: maximumPostFieldsBytes)
      kind = body.object?["kind"]?.stringValue
      if var fields = body.object { fields.removeValue(forKey: "kind"); body = .object(fields) }
      input = try JSONValueDecoder().decode(SessionCreateInput.self, from: body)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-create body: \(error)")
    }
    let payload: ToolResultPayload
    do {
      payload = try await answered {
        try await owner.createSession(principal().session, callID(request), CreateSessionArguments(
          title: input.title, kind: kind, executor: input.executor, topLevel: input.topLevel, group: input.group,
          provider: input.provider, model: input.model, modelGroup: input.modelGroup, effort: input.effort,
          tags: input.tags, template: input.template, expectsReply: input.expectsReply, message: input.message, stallSeconds: input.stallSeconds,
        ))
      }
    } catch let incomplete as IncompleteSession {
      // The session exists: the failure names it.
      return jsonResponse(
        .object(["code": .string(IncompleteSession.code), "message": .string(incomplete.message), "id": .string(incomplete.id.rawValue)]),
        status: .unprocessableContent,
      )
    }
    guard case let .createSession(created) = payload else { return toolRefusal(payload) }
    do {
      let record = try await store.record(created.sessionID)
      let (model, effort): (String?, String?) = switch record.executor {
      case .kernel(let specifier): (specifier.model, specifier.effort)
      case let .modelGroup(_, effort): (try await store.modelRoute(record.id)?.specifier.model, effort)
      case .retired: (nil, nil)
      }
      return try Response.json(SessionCreateOutput(
        id: record.id.rawValue,
        executor: record.executor.kind,
        model: model,
        provider: await activeModelSpecifier(record, store: store)?.provider,
        modelGroup: { if case let .modelGroup(id, _) = record.executor { id } else { nil } }(),
        effort: effort,
        kind: record.kind == .agent ? .agent : .task,
        parent: record.parent?.rawValue,
        title: created.title,
        requestId: created.requestID?.rawValue,
        member: created.member,
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
    let payload = try await answered {
      try await owner.request(principal().session, callID(request), RequestArguments(
        task: id.rawValue, message: input.message, deadlineSeconds: input.deadlineSeconds, stallSeconds: input.stallSeconds,
      ))
    }
    guard case let .request(opened) = payload else { return toolRefusal(payload) }
    return try Response.json(SessionRequestOutput(
      requestId: opened.requestID.rawValue,
      conversationId: opened.conversationID.rawValue,
      deadline: opened.deadline?.timeIntervalSince1970,
    ))
  }

  router.post("/v1/request/:id/report") { request, parameters in
    guard let id = parameters["id"], !id.isEmpty else {
      return errorResponse(.notFound, code: "notFound", message: "unknown request")
    }
    let input: RequestReportInput
    do {
      input = try await request.json(RequestReportInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a request-report body: \(error)")
    }
    let payload = try await answered {
      try await owner.report(principal().session, callID(request), ReportArguments(requestID: id, kind: input.kind.rawValue, content: input.content))
    }
    guard case let .report(reported) = payload else { return toolRefusal(payload) }
    return try Response.json(RequestReportOutput(messageId: reported.messageID.rawValue, conversationId: reported.conversationID.rawValue))
  }

  // A session names only itself.
  router.post("/v1/session/:id/title") { request, parameters in
    guard let id = sessionID(parameters), id == principal().session else { return unknownSession(parameters) }
    let input: SessionTitleInput
    do {
      input = try await request.json(SessionTitleInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-title body: \(error)")
    }
    let payload = try await answered { try await owner.setTitle(principal().session, callID(request), SetTitleArguments(title: input.title)) }
    guard case let .setTitle(titled) = payload else { return toolRefusal(payload) }
    return try Response.json(SessionTitleOutput(title: titled.title))
  }

  router.post("/v1/device/:id/command") { request, parameters in
    guard let device = parameters["id"], !device.isEmpty else { return unknownDevice(parameters) }
    let input: DeviceCommandInput
    do {
      input = try await request.json(DeviceCommandInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a device-command body: \(error)")
    }
    let payload = try await answered {
      try await owner.manipulateUI(principal().session, callID(request), ManipulateUIArguments(device: device, payload: input.payload))
    }
    guard case let .manipulateUI(issued) = payload else { return toolRefusal(payload) }
    return try Response.json(DeviceCommandOutput(n: Int(issued.n)))
  }

  // One durable slot of the session's own, keyed by the tool call that arms
  // it, so a retried arm lands on the same slot.
  router.post("/v1/subscription") { request, _ in
    let input: SubscriptionInput
    do {
      input = try await request.json(SubscriptionInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a subscription body: \(error)")
    }
    let payload: ToolResultPayload
    switch (input.observe, input.timer) {
    case let (observe?, nil):
      payload = try await answered {
        try await owner.observe(principal().session, callID(request), ObserveArguments(sql: observe.sql, throttleSeconds: observe.throttleSeconds, handler: input.handler))
      }
    case let (nil, timer?):
      payload = try await answered {
        try await owner.timer(principal().session, callID(request), TimerArguments(message: timer.message, inSeconds: timer.inSeconds, cron: timer.cron, handler: input.handler))
      }
    default:
      return errorResponse(.badRequest, code: "invalidArgument", message: "a subscription is exactly one of observe and timer")
    }
    guard let output = subscriptionOutput(payload) else { return toolRefusal(payload) }
    return try Response.json(output)
  }
  router.delete("/v1/subscription/:id") { request, parameters in
    guard let id = parameters["id"], !id.isEmpty else {
      return errorResponse(.notFound, code: "notFound", message: "unknown subscription")
    }
    let payload = try await answered { try await owner.cancel(principal().session, callID(request), CancelArguments(id: id)) }
    guard let output = subscriptionOutput(payload) else { return toolRefusal(payload) }
    return try Response.json(output)
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
    if case let .object(fields) = body, fields["viewing"] != nil {
      return errorResponse(.badRequest, code: "invalidArgument", message: "viewing is set only on a person's message, never by a session")
    }
    if case let .object(fields) = body, fields["user"] != nil {
      return errorResponse(.unprocessableContent, code: "refused", message: SessionStoreError.humanAgentDirectMessageExplanation)
    }
    let payload = try await answered {
      try await owner.sendMessage(principal().session, callID(request), SendMessageArguments(
        message: input.message, conversation: input.conversation, session: input.session, replyTarget: input.replyTarget, attachments: input.attachments,
      ))
    }
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

private func subscriptionOutput(_ payload: ToolResultPayload) -> SubscriptionOutput? {
  switch payload {
  case let .observe(armed):
    SubscriptionOutput(id: armed.subscriptionID.rawValue, kind: .observe, fireAt: nil, cron: nil)
  case let .timer(armed):
    switch armed.schedule {
    case let .oneShot(date): SubscriptionOutput(id: armed.subscriptionID.rawValue, kind: .timer, fireAt: date.timeIntervalSince1970, cron: nil)
    case let .cron(expression): SubscriptionOutput(id: armed.subscriptionID.rawValue, kind: .timer, fireAt: nil, cron: expression)
    }
  case let .cancelObservation(ended):
    SubscriptionOutput(id: ended.subscriptionID.rawValue, kind: .observe, fireAt: nil, cron: nil)
  case let .cancelTimer(ended):
    SubscriptionOutput(id: ended.subscriptionID.rawValue, kind: .timer, fireAt: nil, cron: nil)
  default:
    nil
  }
}

// The file tools a session has, each with the argument fields that name what it
// changes; a read names nothing to check.
private let sessionToolFields: [String: [String]] = [
  "read": [], "ls": [], "stat": [], "grep": [], "find": [], "history": [], "query": [],
  "write": ["path"], "edit": ["path"], "rm": ["path"], "mv": ["from", "to"], "checkout": ["path"],
  "table.schema": [], "table.create": ["path"], "table.alter": ["path"], "table.mutate": ["path"], "table.rows": ["path"], "new": ["in"],
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

private func promptScope(_ scope: InstructionScope) -> PromptScope {
  PromptScope(
    sections: scope.sections.map { PromptSection(path: $0.path, text: $0.text) },
    skills: scope.skills.map { SessionHomeSkill(name: $0.name, description: $0.description, path: $0.path) },
  )
}
