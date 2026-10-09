#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import Serve
import ServeRouting
import SpaceCore

private struct IdentitySetInput: Decodable {
  var defaultIssuer: IssuerChoice?
  var audience: String?
  var issuer: IssuerChoice?
  var remove: Bool?
}

func addIdentityRoutes(_ router: inout Router, space: Space, identity: IdentityController?, dev: Bool) {
  @Dependency(\.date) var date
  for path in ["/v1/identity", "/v1/identity/issuer-for"] {
    router.get(path) { request, _ in
      switch try await requestPrincipal(request, space: space, date: date) {
      case .principal: break
      case let .refused(response): return response
      }
      guard let identity else { return identityUnavailable() }
      do {
        if path == "/v1/identity" { return jsonResponse(try await identity.snapshot()) }
        guard let origin = queryValues(of: request.url)["origin"], let url = URL(string: origin),
              try ServerIdentity.audience(url) == origin, fetchOrigin(url) == origin
        else { throw IdentityError.invalidAudience }
        return jsonResponse(.object(["issuer": .string(try await identity.issuerFor(url))]))
      } catch let error as IdentityError { return identityFailure(error) }
    }
  }
  router.post("/v1/identity/register-new") { request, _ in
    guard SessionPrincipal.current == nil else { return adminRequired("replacing the directory issuer") }
    switch try await managementVerdict(request: request, space: space, dev: dev, now: date.now) {
    case let .refused(response): return response
    case let .actor(actor):
      guard actor.isAdmin else { return adminRequired("replacing the directory issuer") }
    }
    guard let identity else { return identityUnavailable() }
    do {
      try await identity.registerNew()
      return jsonResponse(try await identity.snapshot())
    } catch let error as IdentityError { return identityFailure(error) }
  }
  router.post("/v1/identity/rotate") { request, _ in
    guard SessionPrincipal.current == nil else { return adminRequired("rotating the server key") }
    switch try await managementVerdict(request: request, space: space, dev: dev, now: date.now) {
    case let .refused(response): return response
    case let .actor(actor):
      guard actor.isAdmin else { return adminRequired("rotating the server key") }
    }
    guard let identity else { return identityUnavailable() }
    do {
      try await identity.rotate()
      return jsonResponse(.object(["rotating": .bool(true)]))
    } catch let error as IdentityError { return identityFailure(error) }
  }
  router.put("/v1/identity") { request, _ in
    guard SessionPrincipal.current == nil else { return adminRequired("changing the server issuer") }
    switch try await managementVerdict(request: request, space: space, dev: dev, now: date.now) {
    case let .refused(response): return response
    case let .actor(actor):
      guard actor.isAdmin else { return adminRequired("changing the server issuer") }
    }
    guard let identity else { return identityUnavailable() }
    let input: IdentitySetInput
    do { input = try await request.json(IdentitySetInput.self, upTo: 4096) }
    catch { return errorResponse(.badRequest, code: "invalidArgument", message: "expected defaultIssuer: self|directory, or audience and issuer: self|directory (remove: true deletes an override)") }
    guard (input.defaultIssuer != nil && input.audience == nil && input.issuer == nil && input.remove == nil) ||
      (input.defaultIssuer == nil && input.audience != nil && ((input.issuer != nil && input.remove == nil) || (input.issuer == nil && input.remove == true)))
    else { return errorResponse(.badRequest, code: "invalidArgument", message: "set exactly one default or audience override") }
    do {
      try await identity.set(defaultIssuer: input.defaultIssuer, audience: input.audience, choice: input.issuer)
      return jsonResponse(try await identity.snapshot())
    } catch let error as IdentityError { return identityFailure(error) }
  }
}

private func identityUnavailable() -> Response {
  errorResponse(.serviceUnavailable, code: "identityUnavailable", message: "The server identity is unavailable.")
}

func identityFailure(_ error: IdentityError) -> Response {
  let code: String
  let status: Status
  switch error {
  case .directoryUnavailable, .unknownId, .unlistedKey: code = error.directoryCode!; status = .serviceUnavailable
  case .mutationInProgress: code = "identityBusy"; status = .conflict
  case .directoryNotSelected: code = "directoryNotSelected"; status = .unprocessableContent
  default: code = "identityConfiguration"; status = .unprocessableContent
  }
  return errorResponse(status, code: code, message: error.description)
}
