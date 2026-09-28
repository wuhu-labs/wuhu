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
  case anonymous
  case verified(ActingCredential)
  case rejected(Response)
}

// Verification never outlives one request: every call re-reads the live
// account_keys row, so kicking the row kills outstanding assertions at their
// next appearance.
func bearerVerdict(request: Request, space: Space, now: Date) async throws -> BearerVerdict {
  guard let header = request.headers[.authorization] else { return .anonymous }
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
  guard assertion.claims.isLive(at: now) else {
    return .rejected(unauthorized("assertion expired; the wuhu CLI re-mints automatically — run the command again"))
  }
  // A machine or space key must not act as a user principal even with a valid
  // signature over a live row; the rejection is byte-identical to an unknown
  // key so the response leaks neither existence nor capabilities.
  guard !credential.capabilities.isDisjoint(with: [.device, .seat, .contractor]) else {
    return .rejected(unknownKey(identity))
  }
  return .verified(ActingCredential(
    key: credential,
    expiresAt: assertion.claims.expiresAt,
  ))
}

// The one authorization choke point for credential/account management. Every
// management route resolves its actor here: a verified key acts as its account, and the anonymous seat is the
// admin owner principal only behind --dev.
enum ManagementActor: Sendable {
  case devOwner
  case account(AccountRecord)

  var isAdmin: Bool {
    switch self {
    case .devOwner: true
    case let .account(record): record.isAdmin
    }
  }

  var accountID: AccountID? {
    switch self {
    case .devOwner: nil
    case let .account(record): record.id
    }
  }

  func mayManage(_ target: AccountID) -> Bool {
    switch self {
    case .devOwner: true
    case let .account(record): record.isAdmin || record.id == target
    }
  }
}

enum ManagementVerdict: Sendable {
  case actor(ManagementActor)
  case refused(Response)
}

func managementVerdict(request: Request, space: Space, dev: Bool, now: Date) async throws -> ManagementVerdict {
  switch try await bearerVerdict(request: request, space: space, now: now) {
  case let .rejected(response):
    return .refused(response)
  case let .verified(credential):
    guard let record = try await space.account(credential.key.account), record.removedAt == nil else {
      return .refused(unknownKey(try await space.identity()))
    }
    return .actor(.account(record))
  case .anonymous:
    guard dev else {
      return .refused(unauthorized("a bearer assertion is required"))
    }
    return .actor(.devOwner)
  }
}

func adminRequired(_ what: String) -> Response {
  errorResponse(
    .forbidden,
    code: "adminRequired",
    message: "\(what) requires an admin account",
    hint: "ask an admin, or recover offline with the space folder: wuhu user add --space <folder> --admin (server stopped)",
  )
}

private func unknownKey(_ identity: SpaceIdentity) -> Response {
  unauthorized(
    "your device key was revoked for space \(identity.rawValue) (or never enrolled)",
    hint: "re-enroll this device: wuhu login < invite-link (mint one on an enrolled device: wuhu share-login)",
  )
}

private func unauthorized(_ message: String, hint: String? = nil) -> Response {
  errorResponse(.unauthorized, code: "unauthorized", message: message, hint: hint)
}
