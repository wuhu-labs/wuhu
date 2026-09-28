import Dependencies
import Fetch
import Serve
import ServeRouting
import struct SpaceContract.GroupID
import struct SpaceContract.GroupSettings
import struct SpaceContract.GroupSummary
import struct SpaceContract.GroupUpdateInput
import SpaceCore

func addGroupRoutes(_ router: inout Router, space: Space, spaceHost: String?, dev: Bool) {
  @Dependency(\.date) var clock

  // Public discovery: an anonymous caller gets the ids alone, a credential
  // where it stands, and the group the request names changes neither.
  router.get("/v1/groups") { request, _ in
    let standing: GroupStanding
    switch try await requestCredential(request, space: space, date: clock) {
    case let .credential(credential): standing = try await groupStanding(of: credential, space: space, dev: dev)
    case let .refused(response): return response
    }
    return try Response.json(try await space.groups().filter { $0.removedAt == nil }.map { standing.summary(of: $0.id) })
  }

  router.put("/v1/groups/:id") { request, parameters in
    let principal: Principal
    switch try await requestPrincipal(request, space: space, spaceHost: spaceHost, date: clock) {
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

enum GroupStanding {
  /// The --dev seat, which acts in every group.
  case everywhere
  case within(member: Set<GroupID>, readable: Set<GroupID>)

  func summary(of group: GroupID) -> GroupSummary {
    switch self {
    case .everywhere: GroupSummary(id: group.rawValue, member: true, readable: true)
    case let .within(member, readable):
      GroupSummary(id: group.rawValue, member: member.contains(group), readable: readable.contains(group))
    }
  }
}

func groupStanding(of credential: RequestCredential, space: Space, dev: Bool) async throws -> GroupStanding {
  switch credential {
  case let .session(_, group):
    return .within(member: [group], readable: try await space.reads(group))
  case let .person(acting):
    let member = try await space.memberGroups(of: acting.key.account)
    return .within(member: member, readable: try await space.reads(member))
  case .anonymous:
    return dev ? .everywhere : .within(member: [], readable: [])
  }
}
