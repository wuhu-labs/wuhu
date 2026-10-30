import Dependencies
import Fetch
import struct InferenceKit.InferenceMetric
import struct InferenceKit.InferenceMetricsSink
import JSONValue
import class MainHub.Hub
import struct MainHub.TerminalRun
import Serve
import ServeRouting
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceTools

/// A script that runs with no session, by the token main minted for it: an
/// observer's handler in one firing, or a person's script from a terminal, in
/// the group the person acts in and attributed to their own group.
enum SessionlessScript: Hashable, Sendable {
  case observer(Observer)
  case person(TerminalRun)

  var principal: Principal {
    switch self {
    case let .observer(observer): observer.principal
    case let .person(run): run.person.principal
    }
  }

  var group: GroupID {
    switch self {
    case let .observer(observer): observer.group
    case let .person(run): run.group
    }
  }

  /// Who the hub's verbs (createSession, sendMessage, request) act as.
  var caller: Caller {
    switch self {
    case let .observer(observer): .observer(observer)
    case let .person(run): .person(run.person)
    }
  }

  /// Whom the execs its script mints are recorded as.
  var member: String {
    switch self {
    case let .observer(observer): observer.member
    case let .person(run): Person.execCaller(run.account)
    }
  }

  var payer: InferenceMetric.Payer {
    switch self {
    case let .observer(observer):
      guard let firing = observer.firing else { preconditionFailure("a firing token names its firing") }
      return .observer(group: observer.group.rawValue, firing: firing)
    case let .person(run): return .observer(group: run.personalGroup.rawValue, firing: run.id)
    }
  }
}

// The script a request's token stands for, for the length of that request.
enum SessionlessPrincipal {
  @TaskLocal static var current: SessionlessScript?
}

private func script() -> SessionlessScript {
  guard let script = SessionlessPrincipal.current else { preconditionFailure("a sessionless script's route ran outside the session gate") }
  return script
}

private func notForSessionlessScripts() -> Response {
  errorResponse(.forbidden, code: "forbidden", message: "not available to a script without a session")
}

// A sessionless script's token acts as its principal on what an observer's
// handler has: reads, the file tools, the group's secrets and machines, and
// createSession, request and sendMessage. Session verbs and everything else
// refuse it.
func sessionlessRouter(
  space: Space, hub: MachineHub, machines: MachineSeam, owner: Hub, metrics: InferenceMetricsSink, routed: @escaping UpgradingHandler,
) -> Router {
  @Dependency(\.uuid) var uuid
  let forward: RouteHandler = { request, _ in
    switch try await routed(request) {
    case let .response(response): response
    case .webSocket, .boundedWebSocket: notForSessionlessScripts()
    }
  }
  let callID: @Sendable (Request) -> ToolCallID = { request in
    request.headers[ToolCallHeader.name].map(ToolCallID.init(rawValue:)) ?? ToolCallID("wst_\(uuid().uuidString.lowercased())")
  }

  var router = Router()
  for method in [Fetch.Method.get, .post, .put, .patch, .delete] {
    router.on(method, "/*") { _, _ in notForSessionlessScripts() }
  }
  router.webSocket("/*") { _, _ in .response(notForSessionlessScripts()) }

  for path in [
    "/v1/server", "/v1/context", "/v1/groups", "/v1/group/:id", "/v1/secret", "/v1/secret/:name",
    "/v1/conversation/:id/messages", "/v1/conversation/:id/observe", "/v1/conversation/:id/page", "/v1/conversations", "/v1/dm",
  ] {
    router.get(path, use: forward)
  }
  router.get("/v1/f/*", use: forward)
  router.put("/v1/f/*", use: forward)
  addMachineRoutes(to: &router, space: space, hub: hub, owner: owner, machines: machines, routed: routed) { .script(script()) }
  router.get("/v1/observe") { request, _ in
    await observeResponse(space: space, url: request.url, principal: script().principal)
  }
  router.post("/v1/tools/:name") { request, parameters in
    let name = parameters["name"] ?? ""
    guard let spaceTool = SpaceToolbox.all.first(where: { $0.name == name }), sessionToolFields[name] != nil else {
      return notForSessionlessScripts()
    }
    guard let input = JSONValue.parse(try await request.body?.text() ?? "") else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "request body is not valid JSON")
    }
    do {
      return jsonResponse(try await spaceTool.run(SpaceToolContext(space: space, machines: machines, principal: script().principal), input: input))
    } catch let error as ToolRunError {
      switch error {
      case .undecodableInput: return jsonResponse(error.payload, status: .badRequest)
      case .failed: return jsonResponse(error.payload, status: .unprocessableContent)
      }
    }
  }
  router.post("/v1/session") { request, _ in
    try await postSession(request, as: script().caller, callID: callID(request), owner: owner)
  }
  router.post("/v1/session/:id/request") { request, parameters in
    try await postRequest(request, parameters, as: script().caller, callID: callID(request), owner: owner)
  }
  router.post("/v1/conversation/message") { request, _ in
    try await postMessage(request, as: script().caller, callID: callID(request), owner: owner)
  }
  router.post("/v1/inferences") { request, _ in
    try await inferenceReport(request, payer: script().payer, metrics: metrics)
  }
  return router
}
