#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Assertion.SignedAssertion
import Fetch
import Serve
import struct SessionDomain.SessionID
import SpaceCore

struct ActingCredential: Sendable {
  var key: KeyRecord
  var expiresAt: Date
}

enum BearerVerdict: Sendable {
  case missing
  case verified(ActingCredential)
  case rejected(Response)
}

// Verification never outlives one request: every call re-reads the live
// account_keys row, so kicking the row kills outstanding assertions at their
// next appearance.
func bearerVerdict(request: Request, space: Space, now: Date) async throws -> BearerVerdict {
  guard let header = request.headers[.authorization] else { return .missing }
  guard header.hasPrefix("Bearer ") else {
    return .rejected(unauthorized("unsupported authorization scheme; expected: Bearer <assertion>"))
  }
  guard let assertion = SignedAssertion(rawValue: String(header.dropFirst("Bearer ".count))) else {
    return .rejected(unauthorized("malformed bearer assertion"))
  }
  let identity = try await space.identity()
  guard assertion.claims.space == identity.rawValue else {
    return .rejected(unauthorized(
      "this assertion was minted for space \(assertion.claims.space), not \(identity.rawValue)",
      hint: "point the wuhu CLI at this space so it mints a matching assertion: wuhu use <host:port>",
    ))
  }
  guard let credential = try await space.credential(pubkey: assertion.claims.key) else {
    return .rejected(unknownKey(identity))
  }
  guard assertion.hasValidSignature(publicKeyLabel: credential.pubkey) else {
    return .rejected(unauthorized("assertion signature rejected"))
  }
  // A machine or space key must not act as a user principal even with a valid
  // signature over a live row; the rejection is byte-identical to an unknown
  // key so the response leaks neither existence nor capabilities. It precedes
  // the window check, whose refusal would otherwise tell such a key apart.
  guard !credential.capabilities.isDisjoint(with: [.device, .seat]) else {
    return .rejected(unknownKey(identity))
  }
  switch assertion.claims.validity(at: now) {
  case .live: break
  case .expired:
    return .rejected(outsideItsWindow(
      "assertion expired; the wuhu CLI re-mints automatically — run the command again",
      reason: "assertionExpired",
    ))
  case .notYetValid:
    return .rejected(outsideItsWindow("assertion not yet valid", reason: "assertionNotYetValid"))
  }
  return .verified(ActingCredential(
    key: credential,
    expiresAt: assertion.claims.expiresAt,
  ))
}

struct ManagementActor: Sendable {
  let record: AccountRecord
  var isAdmin: Bool { record.isAdmin }
  var accountID: AccountID { record.id }
  func mayManage(_ target: AccountID) -> Bool { record.isAdmin || record.id == target }
}

enum PersonVerdict: Sendable {
  case person(ResolvedPerson)
  case refused(Response)
}

func personVerdict(request: Request, space: Space, devPerson: ResolvedPerson?, now: Date) async throws -> PersonVerdict {
  switch try await bearerVerdict(request: request, space: space, now: now) {
  case let .rejected(response): return .refused(response)
  case let .verified(credential):
    return .person(ResolvedPerson(account: credential.key.account, persona: try await space.adoptPersona(key: credential.key).name))
  case .missing:
    guard let devPerson else { return .refused(unauthorized("a bearer assertion is required")) }
    guard let record = try await space.account(devPerson.account), record.removedAt == nil else {
      return .refused(unauthorized("the dev person is no longer live"))
    }
    return .person(devPerson)
  }
}

enum ManagementVerdict: Sendable {
  case actor(ManagementActor)
  case refused(Response)
}

func managementVerdict(request: Request, space: Space, devPerson: ResolvedPerson?, now: Date) async throws -> ManagementVerdict {
  switch try await personVerdict(request: request, space: space, devPerson: devPerson, now: now) {
  case let .refused(response): return .refused(response)
  case let .person(person):
    guard let record = try await space.account(person.account), record.removedAt == nil else {
      return .refused(unknownKey(try await space.identity()))
    }
    return .actor(ManagementActor(record: record))
  }
}

func adminRequired(_ what: String) -> Response {
  errorResponse(
    .forbidden,
    code: "adminRequired",
    message: "\(what) requires an admin of shared",
    hint: "ask an admin of shared, or recover offline with the space folder: wuhu user add --space <folder> --admin (server stopped)",
  )
}

private func unknownKey(_ identity: SpaceIdentity) -> Response {
  unauthorized(
    "your device key was revoked for space \(identity.rawValue) (or never enrolled)",
    hint: "re-enroll this device: wuhu login < invite-link (mint one on an enrolled device: wuhu share-login)",
  )
}

// The key is still good; only the assertion's times missed the server's clock.
// `reason` tells a client to re-sign by the server's `now` (GET /v1/server)
// rather than sign the person out; code and message stay what older clients
// already read.
private func outsideItsWindow(_ message: String, reason: String) -> Response {
  errorResponse(
    .unauthorized,
    code: "unauthorized",
    message: message,
    hint: "check that this device's date and time are set automatically, then try again",
    reason: reason,
  )
}

private func unauthorized(_ message: String, hint: String? = nil) -> Response {
  errorResponse(.unauthorized, code: "unauthorized", message: message, hint: hint)
}
