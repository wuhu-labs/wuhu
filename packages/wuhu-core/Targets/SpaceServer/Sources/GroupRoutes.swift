import Dependencies
import Fetch
import Serve
import ServeRouting
import struct SpaceContract.GroupAccessEntry
import struct SpaceContract.GroupAccessInput
import struct SpaceContract.GroupDetail
import struct SpaceContract.GroupID
import struct SpaceContract.GroupSummary
import struct SpaceContract.GroupUpdateInput
import SpaceCore
import SpaceTools

func addGroupRoutes(
  _ router: inout Router,
  space: Space,
  dev: Bool,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
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

  // A group's admin state: open or private, the secrets switch, and the list.
  // Its people and its admins see it; anyone else does not.
  router.get("/v1/group/:id") { request, parameters in
    guard let group = groupID(parameters) else { return unknownGroup(parameters) }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    do {
      guard try await space.role(of: principal, in: group) != nil else { return unknownGroup(parameters) }
      return try await Response.json(try groupDetail(group, principal: principal, space: space))
    } catch { return groupErrorResponse(error) }
  }

  // Open/private and the secrets switch: a group admin's call.
  router.put("/v1/group/:id") { request, parameters in
    guard let group = groupID(parameters) else { return unknownGroup(parameters) }
    let input: GroupUpdateInput
    do {
      input = try await request.json(GroupUpdateInput.self)
    } catch {
      return errorResponse(
        .badRequest, code: "invalidArgument",
        message: "expected a group body {\"open\": bool, \"secrets\": \"owner\" | \"reachable\"}: \(error)",
      )
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    guard input.open != nil || input.secrets != nil else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "a group update names open, secrets, or both")
    }
    let secrets: ReachScope?
    if let raw = input.secrets {
      guard let scope = ReachScope(rawValue: raw) else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "secrets is owner or reachable, not \(raw)")
      }
      secrets = scope
    } else {
      secrets = nil
    }
    do {
      if let open = input.open {
        try await space.setVisibility(open ? .open : .private, of: group, by: principal.actor, acting: principal.group)
      }
      if let secrets {
        try await space.setSecretsScope(secrets, of: group, by: principal.actor, acting: principal.group)
      }
      return try await Response.json(try groupDetail(group, principal: principal, space: space))
    } catch { return groupErrorResponse(error) }
  }

  // A private group's list: put names an account or a group at a role.
  router.put("/v1/group/:id/access") { request, parameters in
    guard let group = groupID(parameters) else { return unknownGroup(parameters) }
    let input: GroupAccessInput
    do {
      input = try await request.json(GroupAccessInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected an access body {\"kind\", \"id\", \"role\"}: \(error)")
    }
    guard let subject = GroupGrant.Subject(rawValue: input.kind) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "kind is account or group, not \(input.kind)")
    }
    guard let role = GroupRole(rawValue: input.role) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "role is read, write or admin, not \(input.role)")
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    do {
      try await space.setGrant(subject, input.id, role: role, in: group, by: principal.actor, acting: principal.group)
      return jsonResponse(.object([:]))
    } catch { return groupErrorResponse(error) }
  }

  router.delete("/v1/group/:id/access") { request, parameters in
    guard let group = groupID(parameters) else { return unknownGroup(parameters) }
    let query = queryValues(of: request.url)
    guard let kind = query["kind"].flatMap(GroupGrant.Subject.init(rawValue:)), let id = query["id"], !id.isEmpty else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "removing an entry takes ?kind=account|group&id=<id>")
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    do {
      try await space.removeGrant(kind, id, in: group, by: principal.actor, acting: principal.group)
      return jsonResponse(.object([:]))
    } catch { return groupErrorResponse(error) }
  }
}

private func groupDetail(_ group: GroupID, principal: Principal, space: Space) async throws -> GroupDetail {
  guard let record = try await space.group(group) else {
    throw SpaceError.notFound(group.rawValue)
  }
  let entries = try await space.grants(of: group, by: principal)
  return GroupDetail(
    id: record.id.rawValue,
    open: record.visibility == .open,
    secrets: record.secretsScope.rawValue,
    personal: record.personalAccount != nil,
    entries: entries.map { GroupAccessEntry(kind: $0.subject.rawValue, id: $0.id, role: $0.role.rawValue) },
  )
}

private func groupID(_ parameters: RouteParameters) -> GroupID? {
  guard let raw = parameters["id"], !raw.isEmpty else { return nil }
  return GroupID(rawValue: raw)
}

private func unknownGroup(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(parameters["id"] ?? "")")
}

private func groupErrorResponse(_ error: any Error) -> Response {
  switch error {
  case SpaceError.notFound:
    return errorResponse(.notFound, code: "notFound", message: "no such account or group")
  case SpaceError.groupForbidden(let group):
    return errorResponse(.forbidden, code: "groupForbidden", message: "you may not administer group \(group)")
  case let SpaceError.personalGroupPrivate(group):
    return errorResponse(.forbidden, code: "personalGroup", message: "group \(group) is its owner's alone")
  case SpaceError.settingsGroupAccess:
    return errorResponse(
      .forbidden, code: "adminRequired",
      message: "the settings group's admins are accounts, not list entries",
      hint: "grant or revoke a space admin with POST /v1/accounts/:id/admin, or wuhu user admin",
    )
  case let error as SpaceError:
    return errorResponse(.badRequest, code: "invalidArgument", message: "\(error)")
  default:
    return errorResponse(.internalServerError, code: "internal", message: "\(error)")
  }
}
