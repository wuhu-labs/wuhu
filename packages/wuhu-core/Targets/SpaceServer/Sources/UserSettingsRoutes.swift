#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import ContentLane
import Dependencies
import Fetch
import Serve
import ServeRouting
import struct SpaceContract.SidebarVisibilityInput
import SpaceCore

func addUserSettingsRoutes(_ router: inout Router, space: Space, dev: Bool) {
  @Dependency(\.date) var dateGen

  router.get("/v1/user/:person/avatar") { request, parameters in
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .refused(response): return response
    case .identity: return try await userAvatarResponse(space: space, person: parameters["person"]!, request: request)
    }
  }

  router.put("/v1/user/me/avatar") { request, _ in
    let principal: String
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): principal = resolved
    case let .refused(response): return response
    }
    let data: Data
    do { data = try await request.body?.data(upTo: UserAvatar.maximumBytes) ?? Data() }
    catch { return errorResponse(.contentTooLarge, code: "invalidArgument", message: "avatar exceeds \(UserAvatar.maximumBytes) bytes") }
    do {
      try await space.setUserAvatar(principal: principal, data: data)
      return Response(status: .noContent)
    } catch UserAvatarError.tooLarge {
      return errorResponse(.contentTooLarge, code: "invalidArgument", message: "avatar exceeds \(UserAvatar.maximumBytes) bytes")
    } catch UserAvatarError.invalidPNG {
      return errorResponse(.badRequest, code: "invalidArgument", message: "avatar must be a PNG")
    } catch SpaceError.notFound {
      return noUserAccount()
    }
  }

  router.delete("/v1/user/me/avatar") { request, _ in
    let principal: String
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): principal = resolved
    case let .refused(response): return response
    }
    do {
      try await space.setUserAvatar(principal: principal, data: nil)
      return Response(status: .noContent)
    } catch SpaceError.notFound { return noUserAccount() }
  }

  router.get("/v1/user/me/settings") { request, _ in
    let principal: String
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): principal = resolved
    case let .refused(response): return response
    }
    do { return try await Response.json(space.userSettings(principal: principal)) }
    catch SpaceError.notFound { return noUserAccount() }
  }

  router.put("/v1/user/me/settings/sidebar") { request, _ in
    let principal: String
    switch try await identityVerdict(nil, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): principal = resolved
    case let .refused(response): return response
    }
    let input: SidebarVisibilityInput
    do { input = try await request.json(SidebarVisibilityInput.self) }
    catch { return errorResponse(.badRequest, code: "invalidArgument", message: "expected {group, path, hidden}") }
    do {
      return try await Response.json(space.setSidebarVisibility(principal: principal, group: input.group, path: input.path, hidden: input.hidden))
    } catch SpaceError.notFound { return noUserAccount() }
  }
}

func userAvatarResponse(space: Space, person: String, request: Request) async throws -> Response {
  guard let avatar = try await space.userAvatar(principal: person) else {
    return errorResponse(.notFound, code: "notFound", message: "no avatar for this person")
  }
  var response = served(avatar.data, contentType: "image/png", version: avatar.hash, shell: nil, group: .shared, headOnly: request.method == .head, range: nil, ifNoneMatch: request.headers[.ifNoneMatch], ifRange: nil)
  response.headers[.cacheControl] = "private, no-cache"
  return response
}

private func noUserAccount() -> Response {
  errorResponse(.notFound, code: "notFound", message: "no such account")
}
