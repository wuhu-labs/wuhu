import Dependencies
import Fetch
import Serve
import ServeRouting
import SpaceCore
import SpaceTools

func addDiscoveryRoutes(_ router: inout Router, space: Space, devPerson: ResolvedPerson?, contentHost: String) {
  @Dependency(\.date) var clock
  router.get("/v1/context") { request, _ in
    let principal: Principal
    switch try await requestPrincipal(request, space: space, devPerson: devPerson, date: clock) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    return try Response.json(try await SpaceToolContext(space: space, principal: principal).discoveryContext(contentHost: contentHost))
  }
}
