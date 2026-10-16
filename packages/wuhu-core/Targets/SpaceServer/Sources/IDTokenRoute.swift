#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Serve
import ServeRouting
import SpaceCore

/// `GET /v1/id-token?audience=<origin>` with `Authorization: Bearer wit_…`: a
/// session's running exec trades the capability in its `WUHU_ID_TOKEN_REQUEST`
/// for a 60-second OIDC token naming its session, machine and exec, so a
/// service that trusts this server's issuer (the build pool) can tell who is
/// calling without a credential of its own. The route authenticates by that
/// capability alone, so it precedes the device wall.
func addIDTokenRoute(_ router: inout Router, space: Space, tokens: ExecTokens?, identity: IdentityController?) {
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  router.get("/v1/id-token") { request, _ in
    let now = date.now
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer \(IDTokenGrants.prefix)"),
          let grant = tokens?.idTokens.grant(ofBearer: String(header.dropFirst("Bearer ".count)), now: now)
    else {
      return errorResponse(.unauthorized, code: "unauthorized", message: "this id-token request is not valid: its exec has ended or passed its timeout, or the server restarted since it started")
    }
    // Any ending counts, machine loss included: a v1 exec that resumes after
    // its machine returns no longer mints, so a copied capability can't
    // outlive the machine's connection.
    guard let exec = try? await space.execRecord(grant.exec), exec.machine == grant.machine, exec.caller == grant.session.rawValue,
          exec.terminal == nil
    else {
      tokens?.idTokens.revoke(grant.exec)
      return errorResponse(.unauthorized, code: "unauthorized", message: "this id-token request's exec \(grant.exec.rawValue) has ended")
    }
    guard let record = try? await space.sessions.record(grant.session),
          let group = try? await space.principal(of: grant.session).group
    else {
      return errorResponse(.unauthorized, code: "unauthorized", message: "unknown session: \(grant.session.rawValue)")
    }
    guard case .live = record.lifecycle else {
      return errorResponse(.forbidden, code: "forbidden", message: "session \(grant.session.rawValue) is archived and may no longer act")
    }
    guard let named = queryValues(of: request.url)["audience"], let audience = URL(string: named), fetchOrigin(audience) == named else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "audience must be an origin: scheme://host[:port], lowercase, without a path")
    }
    guard let identity else {
      return errorResponse(.serviceUnavailable, code: "identityUnavailable", message: "The server identity is unavailable.")
    }
    let lifetime = 60
    do {
      let token = try await identity.token(
        audience: audience, space: space.identity().rawValue, group: group.rawValue, session: grant.session.rawValue,
        now: now, id: uuid(), lifetime: lifetime, exec: ExecClaims(machine: grant.machine.rawValue, exec: grant.exec.rawValue),
      )
      let expiresAt = Int(now.timeIntervalSince1970) + lifetime
      return clockReading(jsonResponse(.object(["token": .string(token), "expiresAt": .integer(expiresAt)])), now: now)
    } catch let error as IdentityError {
      return identityFailure(error)
    }
  }
}
