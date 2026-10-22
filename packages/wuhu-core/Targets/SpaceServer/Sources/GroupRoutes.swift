import Dependencies
import Fetch
import Serve
import ServeRouting
import struct SpaceContract.GroupID
import struct SpaceContract.GroupSummary
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
}
