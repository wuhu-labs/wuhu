import enum Credentials.SecretError
import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Fetch
import ServeRouting
import struct SpaceContract.GroupID
import struct SpaceContract.SecretSetInput
import struct SpaceContract.SecretsOutput
import SpaceCore

// Secrets are the acting group's, with no fallback. Listing takes acting in
// the group; setting one takes an admin of it, and removing one, which can't
// be undone, a human admin. The --dev seat is unrestricted.
func addSecretRoutes(
  _ router: inout Router,
  space: Space,
  secrets: SpaceSecretStores?,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  router.get("/v1/secret") { request, _ in
    try await secretVerdict(secrets, request, principalOf) { store, _ in
      try Response.json(SecretsOutput(names: try await store.names()))
    }
  }
  router.put("/v1/secret/:name") { request, parameters in
    let input: SecretSetInput
    do {
      input = try await request.json(SecretSetInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a secret body {\"value\": ...}: \(error)")
    }
    return try await secretVerdict(secrets, request, principalOf) { store, principal in
      let admitted = if principal.actor == .anonymous { true } else { try await space.isAdmin(principal.actor, of: principal.group) }
      guard admitted else {
        return errorResponse(
          .forbidden, code: "adminRequired",
          message: "setting a secret needs an admin of group \(principal.group.rawValue)",
        )
      }
      try await store.set(parameters["name"] ?? "", to: input.value)
      return jsonResponse(.object([:]))
    }
  }
  router.delete("/v1/secret/:name") { request, parameters in
    try await secretVerdict(secrets, request, principalOf) { store, principal in
      let admitted: Bool = switch principal.actor {
      case .anonymous: true
      case let .person(_, account): try await space.isHumanAdmin(account, of: principal.group)
      case .session: false
      }
      guard admitted else {
        return errorResponse(
          .forbidden, code: "adminRequired",
          message: "removing a secret can't be undone and needs a human admin of group \(principal.group.rawValue)",
        )
      }
      try await store.remove(parameters["name"] ?? "")
      return jsonResponse(.object([:]))
    }
  }
}

private func secretVerdict(
  _ secrets: SpaceSecretStores?,
  _ request: Request,
  _ principalOf: @Sendable (Request) async throws -> PrincipalVerdict,
  _ body: (SpaceSecrets, Principal) async throws -> Response,
) async throws -> Response {
  guard let secrets else {
    return errorResponse(.serviceUnavailable, code: "unavailable", message: "this server has no secret store")
  }
  let principal: Principal
  switch try await principalOf(request) {
  case let .principal(resolved): principal = resolved
  case let .refused(response): return response
  }
  do {
    return try await body(try secrets.group(principal.group.rawValue), principal)
  } catch let error as SecretError {
    switch error {
    case .invalidName, .emptyValue, .invalidGroup:
      return errorResponse(.badRequest, code: "invalidArgument", message: error.description)
    case .unknown:
      return errorResponse(.notFound, code: "notFound", message: error.description)
    case .corrupt:
      throw error
    }
  }
}
