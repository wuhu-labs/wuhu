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
import SpaceCore

/// Who stands behind a request: a session's exec token, a verified person, or
/// an unauthenticated caller (the --dev seat, or a public route).
enum RequestCredential: Sendable {
  case session(SessionID, group: GroupID)
  case person(ActingCredential)
  case anonymous
}

enum PrincipalVerdict: Sendable {
  case principal(Principal)
  case refused(Response)
}

/// A session acts in its own group only. A person names one with the
/// `wuhu-group` header, else acts in `shared`; any other group needs
/// membership.
func principal(for request: Request, credential: RequestCredential, space: Space) async throws -> PrincipalVerdict {
  let named = request.headers[GroupHeader.name]
  if case let .session(session, group) = credential {
    if let refused = groupMismatch(request, session: session, group: group) { return .refused(refused) }
    return .principal(Principal(actor: .session(session), group: group))
  }
  let actor: Actor
  switch try await speaker(of: credential, speaking: queryValues(of: request.url)["identity"], in: space) {
  case let .actor(resolved): actor = resolved
  case let .refused(response): return .refused(response)
  }
  guard let named, named != GroupID.shared.rawValue else {
    return .principal(.shared(actor))
  }
  let group = GroupID(rawValue: named)
  guard try await space.groupExists(group) else {
    return .refused(errorResponse(.notFound, code: "unknownGroup", message: "this space has no group \(named)"))
  }
  if case let .person(_, account) = actor, try await !space.isMember(account, of: group) {
    return .refused(errorResponse(.forbidden, code: "groupForbidden", message: "you are not a member of group \(named)"))
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
  return request.headers[GroupHeader.name].map(GroupID.init(rawValue:)) ?? .shared
}

/// A session naming another group than its own.
func groupMismatch(_ request: Request, session: SessionID, group: GroupID) -> Response? {
  guard let named = request.headers[GroupHeader.name], named != group.rawValue else { return nil }
  return errorResponse(
    .forbidden, code: "groupMismatch",
    message: "session \(session.rawValue) acts in its own group \(group.rawValue) only, not \(named)",
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
  case let .person(acting):
    if claimed == nil, acting.key.capabilities.isDisjoint(with: [.device, .seat]) {
      return .actor(try await person(acting.key.account, in: space))
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
  guard let viewer else { return Principal(actor: .anonymous, group: group) }
  return Principal(actor: try await person(viewer, in: space), group: group)
}

private func person(_ account: AccountID, in space: Space) async throws -> Actor {
  .person(persona: try await space.persona(account: account)?.name ?? account.rawValue, account: account)
}
