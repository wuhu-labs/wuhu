#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Dependencies.DateGenerator
import Fetch
import Serve
import struct SessionDomain.SessionID
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupID
import let SpaceContract.ownerIdentity
import SpaceCore

/// Who stands behind a request: a session's exec token, a sessionless
/// script's token, a verified person, or an unauthenticated caller (the --dev
/// seat, or a public route).
enum RequestCredential: Sendable {
  case session(SessionID, group: GroupID)
  case script(SessionlessScript)
  case person(ActingCredential)
  case anonymous
}

enum PrincipalVerdict: Sendable {
  case principal(Principal)
  case refused(Response)
}

/// A session acts in its own group only. A person names one with the
/// `wuhu-group` header, else acts in `shared`; a group they may not read is
/// refused. The --dev seat acts anywhere that exists.
func principal(for request: Request, credential: RequestCredential, space: Space) async throws -> PrincipalVerdict {
  let named = request.headers[GroupHeader.name]
  switch credential {
  case let .session(session, group):
    if let refused = try await groupMismatch(request, by: "session \(session.rawValue)", group: group, space: space) { return .refused(refused) }
    return .principal(Principal(actor: .session(session), group: group))
  case let .script(script):
    if let refused = try await groupMismatch(request, by: "script \(script.member)", group: script.group, space: space) { return .refused(refused) }
    return .principal(script.principal)
  case .person, .anonymous: break
  }
  let actor: Actor
  switch try await speaker(of: credential, speaking: queryValues(of: request.url)["identity"], in: space) {
  case let .actor(resolved): actor = resolved
  case let .refused(response): return .refused(response)
  }
  guard let named, named != GroupID.shared.rawValue else {
    if case .person = actor, try await space.role(of: actor, in: .shared, acting: .shared) == nil {
      return .refused(errorResponse(
        .forbidden, code: "groupForbidden", message: "you may not read group \(GroupID.shared.rawValue)",
      ))
    }
    return .principal(.shared(actor))
  }
  guard let group = try await space.resolveGroup(named) else {
    return .refused(errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(named)"))
  }
  if case .anonymous = actor { return .principal(Principal(actor: actor, group: group)) }
  guard try await space.role(of: actor, in: group, acting: group) != nil else {
    return .refused(errorResponse(.forbidden, code: "groupForbidden", message: "you may not read group \(named)"))
  }
  return .principal(Principal(actor: actor, group: group))
}

enum CredentialVerdict: Sendable {
  case credential(RequestCredential)
  case refused(Response)
}

/// Who stands behind a request on the API origin, whatever group it names:
/// the gated session, else the bearer.
func requestCredential(_ request: Request, space: Space, date: DateGenerator) async throws -> CredentialVerdict {
  if let gated = SessionPrincipal.current { return .credential(.session(gated.session, group: gated.group)) }
  if let script = SessionlessPrincipal.current { return .credential(.script(script)) }
  switch try await bearerVerdict(request: request, space: space, now: date.now) {
  case let .rejected(response): return .refused(response)
  case let .verified(credential): return .credential(.person(credential))
  case .anonymous: return .credential(.anonymous)
  }
}

/// The principal of a request on the API origin: its credential, acting in
/// the group the request names.
func requestPrincipal(_ request: Request, space: Space, date: DateGenerator) async throws -> PrincipalVerdict {
  switch try await requestCredential(request, space: space, date: date) {
  case let .credential(credential): try await principal(for: request, credential: credential, space: space)
  case let .refused(response): .refused(response)
  }
}

/// The group a request names, unchecked: the gated session's, else the
/// header's, else `shared`.
func namedGroup(_ request: Request) -> GroupID {
  if let gated = SessionPrincipal.current { return gated.group }
  if let script = SessionlessPrincipal.current { return script.group }
  return request.headers[GroupHeader.name].map(GroupID.init(rawValue:)) ?? .shared
}

/// A session or sessionless script naming another group than its own.
func groupMismatch(_ request: Request, by member: String, group: GroupID, space: Space) async throws -> Response? {
  guard let named = request.headers[GroupHeader.name], try await space.resolveGroup(named) != group else { return nil }
  return errorResponse(
    .forbidden, code: "groupMismatch",
    message: "\(member) acts in its own group \(group.rawValue) only, not \(named)",
  )
}

/// A person speaks as the persona its request names with `?identity=` when
/// that persona is its account's, else as its account's first.
private enum ActorVerdict {
  case actor(Actor)
  case refused(Response)
}

// A person speaks as the persona the identity routes would give them; a key
// that carries none and claims none acts as its account.
private func speaker(of credential: RequestCredential, speaking claimed: String?, in space: Space) async throws -> ActorVerdict {
  switch credential {
  case let .session(session, _):
    return .actor(.session(session))
  case let .script(script):
    return .actor(script.principal.actor)
  case let .person(acting):
    if claimed == nil, acting.key.capabilities.isDisjoint(with: [.device, .seat]) {
      return .actor(.person(persona: try await persona(of: acting.key.account, in: space), account: acting.key.account))
    }
    switch try await personaVerdict(claimed, key: acting.key, space: space) {
    case let .verified(persona, _): return .actor(.person(persona: persona.name, account: persona.account))
    case let .refused(response): return .refused(response)
    case .anonymous: return .actor(.anonymous)
    }
  case .anonymous:
    return .actor(.anonymous)
  }
}

/// The content origin's reader: the cookie's account, in the Host's group.
func webPrincipal(_ viewer: AccountID?, group: GroupID, space: Space) async throws -> Principal {
  try await webPerson(viewer, group: group, space: space).principal
}

/// The content origin's reader as a person; no account is the --dev seat,
/// speaking as the owner identity.
func webPerson(_ viewer: AccountID?, group: GroupID, space: Space) async throws -> Person {
  guard let viewer else { return Person(persona: ownerIdentity, account: nil, group: group) }
  return Person(persona: try await persona(of: viewer, in: space), account: viewer, group: group)
}

private func persona(of account: AccountID, in space: Space) async throws -> String {
  try await space.persona(account: account)?.name ?? account.rawValue
}
