import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import StructuredQueries

public struct ResolvedPerson: Sendable {
  public let account: AccountID
  public let persona: String

  public var actor: Actor { .person(persona: persona, account: account) }

  public init(account: AccountID, persona: String) {
    self.account = account
    self.persona = persona
  }
}

public enum DevPersonError: Error, Equatable, Sendable {
  case ownerHandleUnavailable(kind: String)
}

extension Space {
  public func ensureDevPerson() async throws -> ResolvedPerson {
    if let alias = cell.devOwnerAlias() {
      guard alias.kind == .person else { throw DevPersonError.ownerHandleUnavailable(kind: alias.kind.rawValue) }
      guard let owner = cell.personCell(alias.target), let account = cell.account(AccountID(rawValue: owner.key)), account.removedAt == nil else {
        throw DevPersonError.ownerHandleUnavailable(kind: "removed person")
      }
      guard account.kind == .human, !account.guest else { throw DevPersonError.ownerHandleUnavailable(kind: account.guest ? "guest" : account.kind.rawValue) }
      if !account.isAdmin { _ = try await setAdmin(account.id, admin: true) }
      return ResolvedPerson(account: account.id, persona: alias.target)
    }
    let account = try await addAccount(kind: .human, name: "owner", admin: true)
    let pubkey = "ed25519:" + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let key = try await addKey(pubkey, account: account.id, capabilities: [.device], createdBy: account.id, expiresAt: nil)
    let persona = try await adoptPersona(key: key)
    _ = try await setUserProfile(principal: persona.name, handle: "owner", displayName: nil)
    try await removeKey(pubkey: pubkey)
    return ResolvedPerson(account: account.id, persona: persona.name)
  }
}

extension SpaceCell {
  func devOwnerAlias() -> AliasRow? { db.rows(AliasRow.where { $0.name.eq("owner") }).first }
}
