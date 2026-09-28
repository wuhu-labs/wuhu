import Fetch
import Foundation
import Serve
import SpaceContract
import SpaceCore

enum PersonaCredentialVerdict: Sendable {
  case anonymous
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
  case .anonymous:
    return .anonymous
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
    // Most requests find the persona already minted; only the first one from
    // a new account takes the write lock to adopt it.
    if let persona = try await space.persona(account: key.account) {
      return .verified(persona: persona, key: key)
    }
    return .verified(persona: try await space.adoptPersona(key: key), key: key)
  }
  guard claimed != ownerIdentity else { return .refused(ownerIdentityRefused()) }
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
  dev: Bool,
  now: Date,
) async throws -> IdentityVerdict {
  switch try await personaCredentialVerdict(claimed, request: request, space: space, now: now) {
  case let .refused(response):
    return .refused(response)
  case let .verified(persona, _):
    return .identity(persona.name)
  case .anonymous:
    guard dev else {
      return .refused(errorResponse(.unauthorized, code: "unauthorized", message: "a bearer assertion is required"))
    }
    guard let claimed, claimed != ownerIdentity else { return .identity(ownerIdentity) }
    guard try await space.persona(named: claimed) != nil else {
      return .refused(unknownIdentity(claimed))
    }
    return .identity(claimed)
  }
}

private func ownerIdentityRefused() -> Response {
  errorResponse(
    .forbidden,
    code: "ownerIdentityWalled",
    message: "the owner identity acts only for the anonymous seat on a --dev server; this space attributes every action to a minted persona",
    hint: "omit identity — the server derives your persona from the enrolled key",
  )
}

private func unknownIdentity(_ identity: String) -> Response {
  errorResponse(
    .forbidden,
    code: "unknownIdentity",
    message: "unknown identity: \(identity); identities are personas minted by this space",
    hint: "omit identity — the server derives your persona from the enrolled key",
  )
}
