import LoopCore
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
import struct LoopCore.SessionExecution
import MachineContract
import struct MainHub.CreateSessionArguments
import func MainHub.fetchOrigin
import class MainHub.Hub
import struct MainHub.ManipulateUIArguments
import struct MainHub.ObserveArguments
import struct MainHub.ReportArguments
import struct MainHub.RequestArguments
import struct MainHub.RequestTermsArguments
import struct MainHub.ScriptRun
import struct MainHub.SendMessageArguments
import struct MainHub.SetTitleArguments
import struct MainHub.TimerArguments
import Serve
import ServeRouting
import ServeSSE
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import SystemFiles
import TaskLifetime
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
  let gated = sessionRouter(
    space: space, hub: hub, machines: machines, owner: owner, execution: runtime.execution, streams: runtime.streamScope,
    credentials: credentials, identity: identity, metrics: metrics, routed: routed,
  ).upgradingHandler
  let sessionlessRoutes = sessionlessRouter(
    space: space, hub: hub, machines: machines, owner: owner, metrics: metrics, routed: routed,
  ).upgradingHandler
  @Dependency(\.date) var dateGen
  return { request in
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer "), isSessionBearer(String(header.dropFirst("Bearer ".count))) else {
      return try await otherwise(request)
    }
    switch await sessionVerdict(String(header.dropFirst("Bearer ".count)), tokens: tokens, space: space, now: dateGen.now) {
    case let .refused(response):
      return .response(response)
    case let .script(script):
      if let refused = try await groupMismatch(request, by: "script \(script.member)", group: script.group, space: space) {
        return .response(refused)
      }
      return try await SessionlessPrincipal.$current.withValue(script) {
        try await sessionlessRoutes(request)
      }
    case let .session(holder):
      // An exec token acts in its session's group; naming another is refused
      // here, whatever the route.
      if let refused = try await groupMismatch(request, by: "session \(holder.session.rawValue)", group: holder.group, space: space) {
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
  /// A sessionless script's token: an observer's few verbs, as its principal.
  case script(SessionlessScript)
  case refused(Response)
}

func execStillRunning(_ id: ExecID, space: Space) async throws -> ExecRecord? {
  guard let record = try await space.execRecord(id), record.terminal == nil else { return nil }
  return record
}

func sessionVerdict(_ bearer: String, tokens: ExecTokens, space: Space, now: Date) async -> SessionVerdict {
  if let script = tokens.script(ofBearer: bearer) { return .script(script) }
  guard let claims = try? await tokens.identity.credential(String(bearer.dropFirst(ExecTokens.prefix.count))) else {
    return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "this session token is not valid: invalid signature or claims"))
  }
  guard Double(claims.exp) > now.timeIntervalSince1970, Double(claims.iat) <= now.timeIntervalSince1970 else {
    return .refused(errorResponse(.unauthorized, code: "credentialExpired", message: "Session credential expired or not yet valid"))
  }
  if claims.credential == .exec {
    guard (try? await execStillRunning(claims.exec!, space: space)) != nil
    else { return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "Session exec ended or is unavailable")) }
  }
  guard let record = try? await space.sessions.record(claims.session),
        let group = try? await space.principal(of: claims.session).group
  else { return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "unknown session: \(claims.session.rawValue)")) }
  guard claims.group == group else { return .refused(errorResponse(.forbidden, code: "groupForbidden", message: "Session group changed")) }
  guard case .live = record.lifecycle else {
    return .refused(errorResponse(.forbidden, code: "forbidden", message: "session \(claims.session.rawValue) is archived and may no longer act"))
  }
  return .session(GatedSession(session: claims.session, group: group, exec: claims.credential == .exec))
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
  execution: SessionExecution,
  streams: TaskScope,
  credentials: CredentialResolver,
  identity: IdentityController?,
  metrics: InferenceMetricsSink,
  routed: @escaping UpgradingHandler,
) -> Router {
  let store = space.sessions
  @Dependency(\.uuid) var uuid
  let forward: RouteHandler = { request, _ in
    switch try await routed(request) {
    case let .response(response): response
    case .webSocket, .boundedWebSocket: notForSessions()
    }
  }
  let callID: @Sendable (Request) -> ToolCallID = { request in
    request.headers[ToolCallHeader.name].map(ToolCallID.init(rawValue:)) ?? ToolCallID("wst_\(uuid().uuidString.lowercased())")
  }
  // A session verb runs on the hub as the session, and answers as the tool
  // would: a typed failure is a 422 carrying its code.
  let answered: @Sendable (@Sendable () async throws -> ToolResultPayload) async throws -> ToolResultPayload = { body in
    try await owner.answering(as: .session(principal().session), body)
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
  router.get("/v1/group/:id", use: forward)
  router.get("/v1/group/:id/observers", use: forward)
  router.post("/v1/group/:id/observers", use: forward)
  router.delete("/v1/group/:id/observers/:name", use: forward)
  router.post("/v1/groups") { request, parameters in
    guard !principal().exec else {
      return errorResponse(.forbidden, code: "unauthorized", message: "sessions create groups only through createGroup in run_script")
    }
    return try await forward(request, parameters)
  }
  // A session names a group it administers; its alias and access stay a person's.
  router.put("/v1/group/:id") { request, parameters in
    let text = try await request.body?.text() ?? ""
    guard !principal().exec, case let .object(fields)? = JSONValue.parse(text), Array(fields.keys) == ["name"] else {
      return errorResponse(.forbidden, code: "unauthorized", message: "a session changes only a group's name, through setGroupName in run_script")
    }
    var named = request
    named.body = .bytes(Data(text.utf8), contentType: "application/json")
    return try await forward(named, parameters)
  }
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
  router.get("/v1/id-token", use: forward)
  addMachineRoutes(to: &router, space: space, hub: hub, owner: owner, machines: machines, routed: routed) {
    .session(principal().session, group: principal().group)
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
    return try await MachineSeam.$caller.withValue(principal().session) { try await forward(request, parameters) }
  }
  // The caller's prompt for its generation, rendered by the first read.
  router.get("/v1/prompt") { _, _ in
    do {
      let stored = try await sessionPrompt(space: space, session: principal().session)
      return try Response.json(SessionPromptOutput(
        prompt: stored.preamble.system, tools: try stored.preamble.tools.map { try JSONValueEncoder().encode($0) }, rendered: stored.rendered,
        opening: stored.opening, session: stored.session,
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }
  // Transcript media belongs to the worker's immutable history, not its current file access.
  // Exec credentials are readable by commands and must never reach this route.
  router.get("/v1/media") { request, _ in
    guard !principal().exec else {
      return errorResponse(.forbidden, code: "unauthorized", message: "media is read by the session's worker, never from an exec")
    }
    guard let address = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
          let url = URL(string: address), let reference = MediaReference(url)
    else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "media is named by a wuhu-blob: or wuhu-space: URL")
    }
    do {
      let bytes = try await space.mediaBytes(reference, group: principal().group)
      return Response(status: .ok, body: .bytes(bytes, contentType: "application/octet-stream"))
    } catch SpaceError.notFound {
      return errorResponse(.notFound, code: "notFound", message: "no media \(address)")
    } catch {
      return sessionErrorResponse(error)
    }
  }
  // Only the worker reports; an exec's token would let any command bill its
  // session.
  router.post("/v1/inferences") { request, _ in
    guard !principal().exec else {
      return errorResponse(.forbidden, code: "unauthorized", message: "an inference is reported by the session's worker, never from an exec")
    }
    return try await inferenceReport(request, payer: .session(principal().session), metrics: metrics)
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

  // The session's worker runs the file; the stream closing kills it.
  router.post("/v1/scripts") { request, _ in
    let input = try await request.json(ScriptRunInput.self)
    let script = ScriptRun(runner: .session(principal().session, group: principal().group), source: input.source, arguments: input.arguments)
    return scriptStream(in: streams) { say in try await execution.run(script, output: say) }
  }
  router.post("/v1/exec/:id/background") { _, parameters in
    guard let raw = parameters["id"], let record = try await space.execRecord(ExecID(rawValue: raw)), record.caller == principal().session.rawValue else { return unknownExec(parameters) }
    try await space.worker.call(MachineCell.ID(record.machine.rawValue)) { try $0.background(raw) }
    return try Response.json(JSONValue.object([:]))
  }
  router.post("/v1/session") { request, _ in
    try await postSession(request, as: .session(principal().session), callID: callID(request), owner: owner)
  }

  router.post("/v1/session/:id/request") { request, parameters in
    try await postRequest(request, parameters, as: .session(principal().session), callID: callID(request), owner: owner)
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
    guard case let .report(reported) = payload else { return hubRefusal(payload) }
    return try Response.json(RequestReportOutput(messageId: reported.messageID.rawValue, conversationId: reported.conversationID.rawValue))
  }

  // A session names only itself.
  router.post("/v1/session/:id/title") { request, parameters in
    guard let id = sessionID(parameters), id == principal().session else { return unknownSession(parameters) }
    return try await forward(request, parameters)
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
      try await owner.manipulateUI(principal().session, ManipulateUIArguments(device: device, payload: input.payload))
    }
    guard case let .manipulateUI(issued) = payload else { return hubRefusal(payload) }
    return try Response.json(DeviceCommandOutput(n: Int(issued.n)))
  }

  // One durable slot of the session's own, keyed by the tool call that arms
  // it, so a retried arm lands on the same slot. Main checks what is armed;
  // the session's cell arms and ends it.
  router.post("/v1/subscription") { request, _ in
    let input: SubscriptionInput
    do {
      input = try await request.json(SubscriptionInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a subscription body: \(error)")
    }
    let payload: ToolResultPayload
    let (session, call) = (principal().session, callID(request))
    switch (input.observe, input.timer) {
    case let (observe?, nil):
      payload = try await answered {
        let arming = try await owner.arming(session, call, ObserveArguments(sql: observe.sql, url: observe.url, throttleSeconds: observe.throttleSeconds, handler: input.handler, name: input.name))
        return try await execution.arm(session, arming)
      }
    case let (nil, timer?):
      payload = try await answered {
        let arming = try owner.arming(call, TimerArguments(message: timer.message, inSeconds: timer.inSeconds, cron: timer.cron, handler: input.handler, name: input.name))
        return try await execution.arm(session, arming)
      }
    default:
      return errorResponse(.badRequest, code: "invalidArgument", message: "a subscription is exactly one of observe and timer")
    }
    guard let output = subscriptionOutput(payload) else { return hubRefusal(payload) }
    return try Response.json(output)
  }
  router.delete("/v1/subscription/:id") { request, parameters in
    guard let id = parameters["id"], !id.isEmpty else {
      return errorResponse(.notFound, code: "notFound", message: "unknown subscription")
    }
    let payload = try await answered { try await execution.disarm(principal().session, SubscriptionID(id)) }
    guard let output = subscriptionOutput(payload) else { return hubRefusal(payload) }
    return try Response.json(output)
  }

  for verb in ["interrupt", "resume", "archive", "unarchive", "tags"] {
    router.post("/v1/session/:id/\(verb)") { request, parameters in
      guard let id = sessionID(parameters) else { return unknownSession(parameters) }
      do {
        if verb == "archive" || verb == "unarchive" {
          try await store.refuseArchiving(id, by: .session(principal().session), acting: principal().group)
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
    try await postMessage(request, as: .session(principal().session), callID: callID(request), owner: owner)
  }
  return router
}

// What a script says, as server-sent events; the stream closing kills it.
func scriptStream(in streams: TaskScope, _ run: @escaping @Sendable (@escaping @Sendable (ScriptOutput) -> Void) async throws -> Void) -> Response {
  let events = AsyncStream<SSEEvent> { continuation in
    let say: @Sendable (ScriptOutput) -> Void = { output in
      if let event = try? SSEEvent.json(output) { continuation.yield(event) }
    }
    let task = try? streams.run("wuhu-script") {
      do { try await run(say) }
      catch is CancellationError {}
      catch { say(.failure(message: "the script did not run to its end: \(error)")) }
      continuation.finish()
    }
    if task == nil { continuation.finish() }
    continuation.onTermination = { _ in task?.cancel() }
  }
  return .sse(events)
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
let sessionToolFields: [String: [String]] = [
  "read": [], "ls": [], "stat": [], "grep": [], "find": [], "history": [], "query": [],
  "write": ["path"], "edit": ["path"], "rm": ["path"], "mv": ["from", "to"], "copy": ["to"], "checkout": ["path"],
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
      let target: GroupID
      if let named = resolved.group {
        guard let id = try await space.resolveGroup(named) else { continue }
        target = id
      } else { target = home }
      try SessionHome.refuseForeignWrite(to: path, in: target, by: session, home: home)
    } catch {
      return jsonResponse(Wire.failure(error).payload, status: .unprocessableContent)
    }
  }
  return nil
}

// One inference a worker ran, into the server's metrics, once per attempt id
// however often it is reported.
func inferenceReport(_ request: Request, payer: InferenceMetric.Payer, metrics: InferenceMetricsSink) async throws -> Response {
  let input = try await request.json(InferenceReportInput.self)
  guard let outcome = InferenceMetric.Outcome(rawValue: input.outcome) else {
    return errorResponse(.badRequest, code: "invalidArgument", message: "unknown inference outcome: \(input.outcome)")
  }
  let usage = input.usage.map { [$0.inputTokens, $0.outputTokens, $0.cacheReadTokens, $0.cacheWriteTokens, $0.reasoningTokens ?? 0, $0.totalTokens] } ?? []
  guard !input.id.isEmpty, input.timestamp.isFinite, ([input.durationMs, input.ttftMs ?? 0, input.status ?? 0] + usage).allSatisfy({ $0 >= 0 }) else {
    return errorResponse(.badRequest, code: "invalidArgument", message: "an inference report names its attempt and counts nothing negative")
  }
  await metrics.record(InferenceMetric(
    id: input.id, timestamp: Date(timeIntervalSince1970: input.timestamp), payer: payer,
    provider: input.provider, model: input.model, servedModel: input.servedModel, effort: input.effort,
    outcome: outcome, errorKind: input.errorKind, status: input.status,
    ttftMs: input.ttftMs.map(Int64.init), durationMs: Int64(input.durationMs),
    usage: input.usage.map {
      Usage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheWriteTokens: $0.cacheWriteTokens, reasoningTokens: $0.reasoningTokens, totalTokens: $0.totalTokens)
    },
  ))
  return jsonResponse(.object([:]))
}
