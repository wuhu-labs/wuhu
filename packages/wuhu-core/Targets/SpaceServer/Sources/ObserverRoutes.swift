import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MainHub.ArmingProblem
import class MainHub.Hub
import Serve
import ServeRouting
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceContract.ObserverInput
import struct SpaceContract.ObserverOutput
import struct SpaceContract.ObserversOutput
import enum SpaceContract.SubscriptionKindPayload
import SpaceCore
import SpaceTools

// A group's observers: write on the group arms and cancels one, read lists
// them; the --dev seat does all three. An observer's own credential never
// reaches these routes.
func addObserverRoutes(
  _ router: inout Router,
  space: Space,
  hub: Hub,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  func acting(
    _ needed: GroupRole,
    _ body: @escaping @Sendable (Request, RouteParameters, GroupID) async throws -> Response,
  ) -> RouteHandler {
    { request, parameters in
      guard let group = try await space.resolveGroup(parameters["id"] ?? "") else {
        return errorResponse(.notFound, code: "notFound", message: "this space has no group \(parameters["id"] ?? "")")
      }
      switch try await principalOf(request) {
      case let .principal(principal):
        if principal.actor != .anonymous {
          guard let role = try await space.role(of: principal, in: group), role >= needed else {
            return errorResponse(.forbidden, code: "forbidden", message: "\(needed.rawValue) on group \(group.rawValue) is needed for its observers")
          }
        }
        do { return try await body(request, parameters, group) }
        catch { return observerErrorResponse(error) }
      case let .refused(response): return response
      }
    }
  }

  router.post("/v1/group/:id/observers", use: acting(.write) { request, _, group in
    let input: ObserverInput
    do { input = try await request.json(ObserverInput.self) }
    catch { return errorResponse(.badRequest, code: "invalidArgument", message: "expected an observer body: \(error)") }
    return try Response.json(observerOutput(try await hub.armObserver(group, input), group: group), status: .created)
  })
  router.get("/v1/group/:id/observers", use: acting(.read) { _, _, group in
    try Response.json(ObserversOutput(observers: try await hub.observers(group).map { observerOutput($0, group: group) }))
  })
  router.delete("/v1/group/:id/observers/:name", use: acting(.write) { _, parameters, group in
    try Response.json(observerOutput(try await hub.cancelObserver(group, name: parameters["name"] ?? ""), group: group))
  })
}

func observerOutput(_ armed: ArmedSubscription, group: GroupID) -> ObserverOutput {
  let (kind, sql, url, cron): (SubscriptionKindPayload, String?, URL?, String?) = switch armed.slot.kind {
  case let .observe(sql, _): (.observe, sql, nil, nil)
  case let .stream(url, _): (.observe, nil, url, nil)
  case let .timer(.cron(expression), _): (.timer, nil, nil, expression)
  case .timer(.oneShot, _): (.timer, nil, nil, nil)
  case .requestDeadline, .requestStall: preconditionFailure("a group observer is an observation or a timer")
  }
  return ObserverOutput(
    name: armed.name!, id: armed.slot.id.rawValue, group: group.rawValue, kind: kind, handler: armed.slot.handler!, sql: sql, url: url?.absoluteString, cron: cron,
    fireAt: armed.nextFireAt?.timeIntervalSince1970, status: armed.status == .armed ? .armed : .paused,
    sessionsPerHour: armed.sessionsPerHour!, lastFiredAt: armed.lastFiredAt?.timeIntervalSince1970, lastError: armed.slot.lastError,
  )
}

private func observerErrorResponse(_ error: any Error) -> Response {
  switch error {
  case let error as ObserverRefusal:
    errorResponse(error.code == "conflict" ? .conflict : error.code == "notFound" ? .notFound : .badRequest, code: error.code, message: error.description)
  case let error as ArmingProblem:
    errorResponse(.badRequest, code: "invalidArgument", message: error.message)
  default:
    sessionErrorResponse(error)
  }
}
