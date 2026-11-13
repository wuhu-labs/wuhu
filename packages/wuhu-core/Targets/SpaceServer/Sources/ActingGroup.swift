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

enum RequestCredential: Sendable {
  case session(SessionID, group: GroupID)
  case script(SessionlessScript)
  case person(ResolvedPerson)
}

enum PrincipalVerdict: Sendable {
  case principal(Principal)
  case refused(Response)
}

func principal(for request: Request, credential: RequestCredential, space: Space) async throws -> PrincipalVerdict {
  let named = request.headers[GroupHeader.name]
  switch credential {
  case let .session(session, group):
    if let refused = try await groupMismatch(request, by: "session \(session.rawValue)", group: group, space: space) { return .refused(refused) }
    return .principal(Principal(actor: .session(session), group: group))
  case let .script(script):
    if let refused = try await groupMismatch(request, by: "script \(script.member)", group: script.group, space: space) { return .refused(refused) }
    return .principal(script.principal)
  case .person: break
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
func requestCredential(_ request: Request, space: Space, devPerson: ResolvedPerson?, date: DateGenerator) async throws -> CredentialVerdict {
  if let gated = SessionPrincipal.current { return .credential(.session(gated.session, group: gated.group)) }
  if let script = SessionlessPrincipal.current { return .credential(.script(script)) }
  switch try await personVerdict(request: request, space: space, devPerson: devPerson, now: date.now) {
  case let .refused(response): return .refused(response)
  case let .person(person): return .credential(.person(person))
  }
}

/// The principal of a request on the API origin: its credential, acting in
/// the group the request names.
func requestPrincipal(_ request: Request, space: Space, devPerson: ResolvedPerson?, date: DateGenerator) async throws -> PrincipalVerdict {
  switch try await requestCredential(request, space: space, devPerson: devPerson, date: date) {
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

private func speaker(of credential: RequestCredential, speaking claimed: String?, in space: Space) async throws -> ActorVerdict {
  switch credential {
  case let .session(session, _):
    return .actor(.session(session))
  case let .script(script):
    return .actor(script.principal.actor)
  case let .person(person):
    switch try await identityVerdict(claimed, person: person, space: space) {
    case let .identity(persona): return .actor(.person(persona: persona, account: person.account))
    case let .refused(response): return .refused(response)
    }
  }
}

/// The content origin's reader: the cookie's account, in the Host's group.
func webPrincipal(_ viewer: AccountID?, group: GroupID, space: Space) async throws -> Principal {
  guard let viewer else { return .shared(.publicReader) }
  return try await webPerson(viewer, group: group, space: space).principal
}

func webPerson(_ viewer: AccountID, group: GroupID, space: Space) async throws -> Person {
  return Person(persona: try await persona(of: viewer, in: space), account: viewer, group: group)
}

private func persona(of account: AccountID, in space: Space) async throws -> String {
  try await space.persona(account: account)?.name ?? account.rawValue
}
