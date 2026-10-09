import Dependencies
import Fetch
import Serve
import ServeRouting
import struct SpaceContract.GroupID
import struct SpaceContract.GroupSettings
import struct SpaceContract.GroupSummary
import struct SpaceContract.GroupUpdateInput
import SpaceCore
import SpaceTools

func addGroupRoutes(_ router: inout Router, space: Space, dev: Bool) {
  @Dependency(\.date) var clock

  // Public discovery: an anonymous caller gets the ids alone, a credential
  // where it stands, and the group the request names changes neither.
  router.get("/v1/groups") { request, _ in
    let principal: Principal
    switch try await requestCredential(request, space: space, date: clock) {
    case let .credential(credential):
      principal = switch credential {
      case let .session(id, group): Principal(actor: .session(id), group: group)
      case let .person(acting): Principal(actor: .person(persona: "", account: acting.key.account), group: .shared)
      case .anonymous: .shared(.anonymous)
      }
    case let .refused(response): return response
    }
    return try Response.json(try await SpaceToolContext(space: space, principal: principal).discoveryGroups(dev: dev))
  }

  router.put("/v1/groups/:id") { request, parameters in
    let principal: Principal
    switch try await requestPrincipal(request, space: space, date: clock) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    let group = GroupID(rawValue: parameters["id"] ?? "")
    guard try await space.groupExists(group) else {
      return errorResponse(.notFound, code: "unknownGroup", message: "no group \(group.rawValue)")
    }
    let input: GroupUpdateInput
    do {
      input = try await request.json(GroupUpdateInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a group-update body: \(error)")
    }
    // The --dev seat is unrestricted, as for layer writes.
    let admitted = if principal.actor == .anonymous { true } else { try await space.isAdmin(principal.actor, of: group) }
    guard admitted else {
      return errorResponse(.forbidden, code: "forbidden", message: "only an admin of \(group.rawValue) changes its settings")
    }
    if let on = input.spaceLayer { try await space.setSpaceLayer(group, on: on) }
    return try Response.json(GroupSettings(id: group.rawValue, spaceLayer: try await space.spaceLayer(of: group)))
  }
}
