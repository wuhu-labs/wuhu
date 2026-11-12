#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import func MainHub.fetchOrigin
import Serve
import ServeRouting
import SpaceCore

func addIDTokenRoute(_ router: inout Router, space: Space, tokens: ExecTokens?, identity: IdentityController?) {
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  router.get("/v1/id-token") { request, _ in
    let now = date.now
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer " + ExecTokens.prefix), let tokens,
          let claims = try await tokens.identity.credential(String(header.dropFirst("Bearer ".count + ExecTokens.prefix.count)))
    else { return errorResponse(.unauthorized, code: "unauthorized", message: "a signed session credential is required") }
    switch await sessionVerdict(String(header.dropFirst("Bearer ".count)), tokens: tokens, space: space, now: now) {
    case let .refused(response): return response
    case .session: break
    case .script: preconditionFailure("a signed exec credential cannot be a script bearer")
    }
    guard let named = queryValues(of: request.url)["audience"], let audience = URL(string: named), fetchOrigin(audience) == named else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "audience must be an origin: scheme://host[:port], lowercase, without a path")
    }
    guard let identity else {
      return errorResponse(.serviceUnavailable, code: "fetchIdentityUnavailable", message: "The server could not sign an OIDC token.")
    }
    let lifetime = 60
    do {
      let token = try await identity.token(
        audience: audience, space: space.identity().rawValue, group: claims.group.rawValue, session: claims.session.rawValue,
        now: now, id: uuid(), lifetime: lifetime, exec: claims.credential == .exec ? ExecClaims(machine: claims.machine!.rawValue, exec: claims.exec!.rawValue) : nil,
      )
      let expiresAt = Int(now.timeIntervalSince1970) + lifetime
      return clockReading(jsonResponse(.object(["token": .string(token), "expiresAt": .integer(expiresAt)])), now: now)
    } catch let error as IdentityError {
      return identityFailure(error)
    }
  }
}
