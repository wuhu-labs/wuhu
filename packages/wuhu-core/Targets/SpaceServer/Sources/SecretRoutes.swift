import enum Credentials.SecretError
import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Fetch
import ServeRouting
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import struct SpaceContract.SecretSetInput
import struct SpaceContract.SecretsOutput
import SpaceCore

// Secrets are the acting group's, with no fallback; `?group=` names another
// group the acting one reads. Listing takes acting in the group; a value goes
// only to a session's worker (its script's fetch; the gate keeps an exec's
// token out) or the --dev seat; setting one takes an admin of the group the
// secret lives in, and removing one, which can't be undone, a human admin of
// it. The --dev seat is unrestricted.
func addSecretRoutes(
  _ router: inout Router,
  space: Space,
  secrets: SpaceSecretStores?,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  router.get("/v1/secret") { request, _ in
    try await secretVerdict(secrets, space, request, principalOf) { store, _, _ in
      try Response.json(SecretsOutput(names: try await store.names()))
    }
  }
  router.get("/v1/secret/:name") { request, parameters in
    try await secretVerdict(secrets, space, request, principalOf) { store, principal, _ in
      if case .person = principal.actor {
        return errorResponse(.forbidden, code: "unauthorized", message: "a secret's value is read only by a session's script")
      }
      return jsonResponse(.object(["value": .string(try await store.value(of: parameters["name"] ?? ""))]))
    }
  }
  router.put("/v1/secret/:name") { request, parameters in
    let input: SecretSetInput
    do {
      input = try await request.json(SecretSetInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a secret body {\"value\": ...}: \(error)")
    }
    return try await secretVerdict(secrets, space, request, principalOf) { store, principal, group in
      let admitted = if principal.actor == .anonymous { true } else { try await space.isAdmin(principal.actor, of: group, acting: principal.group) }
      guard admitted else {
        var message = "setting a secret needs an admin of group \(group.rawValue)"
        if case let .session(session) = principal.actor { message += await notAdmin(session, of: group, space: space) }
        return errorResponse(.forbidden, code: "adminRequired", message: message)
      }
      try await store.set(parameters["name"] ?? "", to: input.value)
      return jsonResponse(.object([:]))
    }
  }
  router.delete("/v1/secret/:name") { request, parameters in
    try await secretVerdict(secrets, space, request, principalOf) { store, principal, group in
      let name = parameters["name"] ?? ""
      let admitted: Bool = switch principal.actor {
      case .anonymous: true
      case let .person(_, account): try await space.isHumanAdmin(account, of: group)
      case .session, .observer: false
      }
      guard admitted else {
        return errorResponse(
          .forbidden, code: "adminRequired",
          message: "removing secret \(name) can't be undone and needs a human admin of group \(group.rawValue)",
        )
      }
      try await store.remove(name)
      return jsonResponse(.object([:]))
    }
  }
}

/// Why `session` is no admin of `group`, worded for the caller: only a live
/// top-level agent of a group administers it.
func notAdmin(_ session: SessionID, of group: GroupID, space: Space) async -> String {
  guard let caller = try? await space.sessions.record(session) else { return "" }
  if caller.kind == .task { return "; a task never is one" }
  if caller.parent != nil { return "; a child agent never is one" }
  if caller.group != group { return "; you are a top-level agent of group \(caller.group.rawValue), not of \(group.rawValue)" }
  return ""
}

// A group's secrets open to its owner group alone, or — with the switch — to
// every group that writes it. The --dev seat is unrestricted.
private func admitsSecrets(of group: GroupID, principal: Principal, space: Space) async throws -> Bool {
  if case .anonymous = principal.actor { return true }
  guard let record = try await space.group(group) else { return false }
  switch record.secretsScope {
  case .owner:
    return group == principal.group
  case .reachable:
    // The acting group's role, as a machine's switch reads it.
    return try await space.writes(principal.group, in: group)
  }
}

private func secretsScopeNote(of group: GroupID, principal: Principal, space: Space) async -> String {
  guard let record = try? await space.group(group) else { return "out of reach" }
  return record.secretsScope == .owner
    ? "open to group \(group.rawValue) alone"
    : "not writable from group \(principal.group.rawValue)"
}

// The store `body` gets is the acting group's, or the `?group=` one when
// the switch and the caller's reach admit it; `body` also gets that group,
// which is the one its admin checks are against.
private func secretVerdict(
  _ secrets: SpaceSecretStores?,
  _ space: Space,
  _ request: Request,
  _ principalOf: @Sendable (Request) async throws -> PrincipalVerdict,
  _ body: (SpaceSecrets, Principal, GroupID) async throws -> Response,
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
    var group = principal.group
    if let named = queryValues(of: request.url)["group"], named != group.rawValue {
      try SpaceSecrets.validate(group: named)
      guard let target = try await space.resolveGroup(named) else {
        return errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(named)")
      }
      guard try await admitsSecrets(of: target, principal: principal, space: space) else {
        return errorResponse(
          .forbidden, code: "unauthorized",
          message: "group \(target.rawValue)'s secrets are \(await secretsScopeNote(of: target, principal: principal, space: space))",
        )
      }
      group = target
    }
    return try await body(try secrets.group(group.rawValue), principal, group)
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
