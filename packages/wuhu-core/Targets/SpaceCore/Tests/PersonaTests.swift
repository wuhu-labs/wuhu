import Foundation
import GRDB
@testable import SpaceCore
import Testing

@Suite
struct PersonaTests {
  func enrolledKey(_ space: Space, pubkey: String = testPubkey("laptop")) async throws -> KeyRecord {
    let account = try await space.addAccount(kind: .human, name: nil)
    return try await space.addKey(pubkey, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
  }

  @Test func everyMintDrawsADistinctName() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let first = try await space.mintPersona(key: key)
    let second = try await space.mintPersona(key: key)
    #expect(first.name != second.name)
    #expect(first.name.split(separator: "-").count >= 3)
    #expect(first.key == key.pubkey)
    #expect(first.account == key.account)
  }

  @Test func personasAndSessionsShareTheAllocationCounter() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let persona = try await space.mintPersona(key: key)
    let session = try await space.allocate(.session, createdBy: "tester")
    #expect(persona.name != session.name)
    let kinds = try await space.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT id, kind FROM allocations ORDER BY id")
        .map { (id: $0["id"] as Int64, kind: $0["kind"] as String) }
    }
    #expect(kinds.map(\.id) == [1, 2])
    #expect(kinds.map(\.kind) == ["persona", "session"])
  }

  @Test func aPersonaTracesToExactlyOneKeyAndAccount() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let persona = try await space.mintPersona(key: key)
    let traced = try await space.writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
        SELECT personas.name, account_keys.pubkey, accounts.id AS account_id
        FROM personas
        JOIN account_keys ON account_keys.pubkey = personas.pubkey
        JOIN accounts ON accounts.id = account_keys.account_id
        WHERE personas.name = ?
        """,
        arguments: [persona.name],
      ).map { (name: $0["name"] as String, pubkey: $0["pubkey"] as String, account: $0["account_id"] as String) }
    }
    #expect(traced.count == 1)
    #expect(traced.first?.pubkey == key.pubkey)
    #expect(traced.first?.account == key.account.rawValue)
  }

  @Test func lookupRoundTripsAndUnknownNamesAreNil() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let minted = try await space.mintPersona(key: key)
    #expect(try await space.persona(named: minted.name) == minted)
    #expect(try await space.persona(named: "free-form-squatter") == nil)
    #expect(try await space.persona(account: key.account) == minted)
    #expect(try await space.persona(account: AccountID(rawValue: "acc_stranger")) == nil)
  }

  @Test func adoptionMintsOnceAndStaysOnTheAccountsFirstDraw() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    #expect(try await space.persona(account: key.account) == nil)
    let adopted = try await space.adoptPersona(key: key)
    #expect(try await space.adoptPersona(key: key) == adopted)
    #expect(try await space.persona(account: key.account) == adopted)
    let later = try await space.mintPersona(key: key)
    #expect(later != adopted)
    #expect(try await space.adoptPersona(key: key) == adopted)

    let sibling = try await space.addKey(
      testPubkey("phone"), account: key.account, capabilities: [.device], createdBy: nil, expiresAt: nil,
    )
    #expect(try await space.adoptPersona(key: sibling) == adopted)
  }
}
