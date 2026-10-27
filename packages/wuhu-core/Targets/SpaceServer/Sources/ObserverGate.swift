import Dependencies
import Fetch
import struct InferenceKit.InferenceMetricsSink
import JSONValue
import class MainHub.Hub
import Serve
import ServeRouting
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceTools

// The observer a request's firing token stands for, for the length of that
// request.
enum ObserverPrincipal {
  @TaskLocal static var current: Observer?
}

private func observer() -> Observer {
  guard let observer = ObserverPrincipal.current else { preconditionFailure("an observer route ran outside the session gate") }
  return observer
}

private func notForObservers() -> Response {
  errorResponse(.forbidden, code: "forbidden", message: "not available to an observer")
}

// A firing's token acts as its group on what a handler has: reads, the file
// tools, the group's secrets and machines, and createSession, request and
// sendMessage. Session verbs and everything else refuse it.
func observerRouter(
  space: Space, hub: MachineHub, machines: MachineSeam, owner: Hub, metrics: InferenceMetricsSink, routed: @escaping UpgradingHandler,
) -> Router {
  @Dependency(\.uuid) var uuid
  let forward: RouteHandler = { request, _ in
    switch try await routed(request) {
    case let .response(response): response
    case .webSocket, .boundedWebSocket: notForObservers()
    }
  }
  let callID: @Sendable (Request) -> ToolCallID = { request in
    request.headers[ToolCallHeader.name].map(ToolCallID.init(rawValue:)) ?? ToolCallID("wst_\(uuid().uuidString.lowercased())")
  }

  var router = Router()
  for method in [Fetch.Method.get, .post, .put, .patch, .delete] {
    router.on(method, "/*") { _, _ in notForObservers() }
  }
  router.webSocket("/*") { _, _ in .response(notForObservers()) }

  for path in [
    "/v1/server", "/v1/context", "/v1/groups", "/v1/group/:id", "/v1/secret", "/v1/secret/:name",
    "/v1/conversation/:id/messages", "/v1/conversation/:id/observe", "/v1/conversation/:id/page", "/v1/conversations", "/v1/dm",
  ] {
    router.get(path, use: forward)
  }
  router.get("/v1/f/*", use: forward)
  router.put("/v1/f/*", use: forward)
  addMachineRoutes(to: &router, space: space, hub: hub, owner: owner, machines: machines, routed: routed) { .observer(observer()) }
  router.get("/v1/observe") { request, _ in
    await observeResponse(space: space, url: request.url, principal: observer().principal)
  }
  router.post("/v1/tools/:name") { request, parameters in
    let name = parameters["name"] ?? ""
    guard let spaceTool = SpaceToolbox.all.first(where: { $0.name == name }), sessionToolFields[name] != nil else {
      return notForObservers()
    }
    guard let input = JSONValue.parse(try await request.body?.text() ?? "") else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "request body is not valid JSON")
    }
    do {
      return jsonResponse(try await spaceTool.run(SpaceToolContext(space: space, machines: machines, principal: observer().principal), input: input))
    } catch let error as ToolRunError {
      switch error {
      case .undecodableInput: return jsonResponse(error.payload, status: .badRequest)
      case .failed: return jsonResponse(error.payload, status: .unprocessableContent)
      }
    }
  }
  router.post("/v1/session") { request, _ in
    try await postSession(request, as: .observer(observer()), callID: callID(request), owner: owner)
  }
  router.post("/v1/session/:id/request") { request, parameters in
    try await postRequest(request, parameters, as: .observer(observer()), callID: callID(request), owner: owner)
  }
  router.post("/v1/conversation/message") { request, _ in
    try await postMessage(request, as: .observer(observer()), callID: callID(request), owner: owner)
  }
  router.post("/v1/inferences") { request, _ in
    guard let firing = observer().firing else { preconditionFailure("a firing token names its firing") }
    return try await inferenceReport(request, payer: .observer(group: observer().group.rawValue, firing: firing), metrics: metrics)
  }
  return router
}
