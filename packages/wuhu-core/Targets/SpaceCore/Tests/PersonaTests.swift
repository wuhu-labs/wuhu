import DeterministicDependencies
import Foundation
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies)
struct PersonaTests {
  func enrolledKey(_ space: Space, pubkey: String = testPubkey("laptop")) async throws -> KeyRecord {
    let account = try await space.addAccount(kind: .human, name: nil)
    return try await space.addKey(pubkey, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
  }

  @Test func personasAndSessionsShareTheAllocationCounter() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let persona = try await space.adoptPersona(key: key)
    let session = try await space.allocate(.session, createdBy: "tester")
    #expect(persona.name != session.name)
    #expect(session.id == 2)
    #expect(session.kind == .session)
  }

  @Test func aPersonaTracesToExactlyOneKeyAndAccount() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let persona = try await space.adoptPersona(key: key)
    let traced = try await space.persona(named: persona.name)
    #expect(traced?.key == key.pubkey)
    #expect(traced?.account == key.account)
  }

  @Test func lookupRoundTripsAndUnknownNamesAreNil() async throws {
    let space = try makeSpace()
    let key = try await enrolledKey(space)
    let minted = try await space.adoptPersona(key: key)
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

    let sibling = try await space.addKey(
      testPubkey("phone"), account: key.account, capabilities: [.device], createdBy: nil, expiresAt: nil,
    )
    #expect(try await space.adoptPersona(key: sibling) == adopted)
  }
}
