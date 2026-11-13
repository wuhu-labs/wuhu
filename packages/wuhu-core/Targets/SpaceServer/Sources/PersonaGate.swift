import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Serve
import SpaceContract
import SpaceCore

enum PersonaCredentialVerdict: Sendable {
  case missing
  case verified(persona: PersonaRecord, key: KeyRecord)
  case refused(Response)
}

func personaCredentialVerdict(
  _ claimed: String?,
  request: Request,
  space: Space,
  now: Date,
) async throws -> PersonaCredentialVerdict {
  switch try await bearerVerdict(request: request, space: space, now: now) {
  case let .rejected(response):
    return .refused(response)
  case let .verified(credential):
    return try await personaVerdict(claimed, key: credential.key, space: space)
  case .missing:
    return .missing
  }
}

/// The persona a verified key speaks as: the one `claimed` names, refused
/// when it is another account's, else the account's first. Only device and
/// seat keys carry personas.
func personaVerdict(_ claimed: String?, key: KeyRecord, space: Space) async throws -> PersonaCredentialVerdict {
  guard !key.capabilities.isDisjoint(with: [.device, .seat]) else {
    return .refused(errorResponse(
      .forbidden,
      code: "personaRequiresDevice",
      message: "personas attach to device or seat keys",
      hint: "sign in from an enrolled device: wuhu login",
    ))
  }
  guard let claimed else {
    return .verified(persona: try await space.adoptPersona(key: key), key: key)
  }
  guard let persona = try await space.persona(named: claimed) else {
    return .refused(unknownIdentity(claimed))
  }
  guard persona.account == key.account else {
    return .refused(errorResponse(
      .forbidden,
      code: "identityNotYours",
      message: "persona \(claimed) belongs to another account",
      hint: "omit identity — the server derives your persona from the enrolled key",
    ))
  }
  return .verified(persona: persona, key: key)
}

enum IdentityVerdict: Sendable {
  case identity(String)
  case refused(Response)
}

func identityVerdict(
  _ claimed: String?,
  request: Request,
  space: Space,
  devPerson: ResolvedPerson?,
  now: Date,
) async throws -> IdentityVerdict {
  switch try await personVerdict(request: request, space: space, devPerson: devPerson, now: now) {
  case let .refused(response): return .refused(response)
  case let .person(person): return try await identityVerdict(claimed, person: person, space: space)
  }
}

func identityVerdict(_ claimed: String?, person: ResolvedPerson, space: Space) async throws -> IdentityVerdict {
  guard let claimed else { return .identity(person.persona) }
  guard let persona = try await space.persona(named: claimed) else { return .refused(unknownIdentity(claimed)) }
  guard persona.account == person.account else {
    return .refused(errorResponse(.forbidden, code: "identityNotYours", message: "persona \(claimed) belongs to another account"))
  }
  return .identity(persona.name)
}

private func unknownIdentity(_ identity: String) -> Response {
  errorResponse(
    .forbidden,
    code: "unknownIdentity",
    message: "unknown identity: \(identity); identities are personas minted by this space",
    hint: "omit identity — the server derives your persona from the enrolled key",
  )
}
