#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch
import Serve
import ServeRouting
import SpaceContract
import SpaceCore

func addUserRoutes(_ router: inout Router, space: Space, dev: Bool) {
  @Dependency(\.date) var dateGen

  router.get("/v1/users") { request, _ in
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response):
      return response
    case .identity:
      let profiles = try await space.userProfiles()
      var byPrincipal = Dictionary(uniqueKeysWithValues: profiles.map { ($0.principal, $0) })
      var users: [UserPayload] = try await space.personas().map { persona in
        let profile = byPrincipal.removeValue(forKey: persona.name)
        return UserPayload(id: persona.name, handle: profile?.handle, displayName: profile?.displayName)
      }
      users += byPrincipal.values
        .sorted { $0.principal < $1.principal }
        .map { UserPayload(id: $0.principal, handle: $0.handle, displayName: $0.displayName) }
      return try Response.json(UsersOutput(users: users))
    }
  }

  router.put("/v1/user/me/profile") { request, _ in
    let input: UserProfileInput
    do {
      input = try await request.json(UserProfileInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a user-profile body: \(error)")
    }
    let principal: String
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): principal = resolved
    case let .refused(response): return response
    }
    do {
      let profile = try await space.setUserProfile(
        principal: principal, handle: input.handle, displayName: input.displayName,
      )
      return try Response.json(UserPayload(
        id: profile.principal, handle: profile.handle, displayName: profile.displayName,
      ))
    } catch let SpaceError.invalidHandle(raw) {
      return errorResponse(
        .badRequest,
        code: "invalidHandle",
        message: "invalid handle: \(raw)",
        hint: "handles are 2-32 characters matching [a-z0-9][a-z0-9-]*, compared case-insensitively",
      )
    } catch let SpaceError.handleTaken(handle) {
      return errorResponse(.conflict, code: "handleTaken", message: "handle @\(handle) is already taken")
    }
  }
}

func handles(for principals: some Sequence<String>, space: Space) async throws -> [String: String] {
  let wanted = Set(principals)
  guard !wanted.isEmpty else { return [:] }
  return try await space.handlesByPrincipal().filter { wanted.contains($0.key) }
}
