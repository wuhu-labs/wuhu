import Dependencies
import Foundation
import GRDB
@testable import SpaceCore
import Synchronization
import Testing

@Suite
struct EnrollmentTests {
  @Test func mintAndConsumeEnrollsTheKeyAndKillsTheToken() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: "alice")
    let minter = try await space.addAccount(kind: .human, name: "admin")
    let minted = try await space.mintJoinToken(
      account: owner.id,
      capabilities: [.device, .seat],
      createdBy: minter.id,
      lifetime: 600,
    )
    #expect(JoinToken.isValid(minted.token.rawValue))
    #expect(minted.expiresAt == fixedDate.addingTimeInterval(600))

    let key = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("phone"))
    #expect(key.account == owner.id)
    #expect(key.capabilities == [.device, .seat])
    #expect(key.createdBy == minter.id)
    #expect(key.expiresAt == nil)
    #expect(try await space.credential(pubkey: testPubkey("phone")) == key)

    await #expect(throws: JoinTokenRejected()) {
      _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("other"))
    }
    #expect(try await space.credential(pubkey: testPubkey("other")) == nil)
  }

  @Test func revokingAJoinTokenKillsItBeforeItIsConsumed() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)

    #expect(try await space.revokeJoinToken(minted.token, revocableBy: { _ in true }) == owner.id)
    await #expect(throws: JoinTokenRejected()) {
      _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("phone"))
    }
    #expect(try await space.credential(pubkey: testPubkey("phone")) == nil)

    #expect(try await space.revokeJoinToken(minted.token, revocableBy: { _ in true }) == nil)
    #expect(try await space.revokeJoinToken(JoinToken(rawValue: "not a token"), revocableBy: { _ in true }) == nil)
  }

  @Test func aRefusedRevokeLeavesTheJoinTokenAlive() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)

    await #expect(throws: JoinTokenRevocationRefused(account: owner.id)) {
      _ = try await space.revokeJoinToken(minted.token, revocableBy: { _ in false })
    }
    #expect(try await space.consumeJoinToken(minted.token, pubkey: testPubkey("phone")).account == owner.id)
  }

  @Test func concurrentConsumersOfOneTokenEnrollExactlyOneKey() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    let outcomes = await withTaskGroup(of: Bool.self) { group in
      for i in 0 ..< 8 {
        group.addTask {
          do {
            _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("racer-\(i)"))
            return true
          } catch {
            return false
          }
        }
      }
      return await group.reduce(into: [Bool]()) { $0.append($1) }
    }
    #expect(outcomes.count(where: { $0 }) == 1)
    #expect(try await space.keys(account: owner.id).count == 1)
  }

  @Test func kickedKeyCannotReEnrollWithTheSameToken() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("stolen"))
    try await space.removeKey(pubkey: testPubkey("stolen"))
    await #expect(throws: JoinTokenRejected()) {
      _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("stolen"))
    }
    #expect(try await space.credential(pubkey: testPubkey("stolen")) == nil)

    let fresh = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    _ = try await space.consumeJoinToken(fresh.token, pubkey: testPubkey("stolen"))
    #expect(try await space.credential(pubkey: testPubkey("stolen"))?.account == owner.id)
  }

  @Test func expiredTokenNeverEnrolls() async throws {
    let clock = Mutex(fixedDate)
    let space = try withDependencies {
      $0.date = DateGenerator { clock.withLock { $0 } }
    } operation: {
      try Space.inMemory()
    }
    let owner = try await space.addAccount(kind: .human, name: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    clock.withLock { $0 = fixedDate.addingTimeInterval(600) }
    await #expect(throws: JoinTokenRejected()) {
      _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("late"))
    }
    #expect(try await space.credential(pubkey: testPubkey("late")) == nil)
  }

  @Test func alreadyEnrolledPubkeyLeavesTheTokenAlive() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(testPubkey("dupe"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.seat], createdBy: nil, lifetime: 600)
    await #expect(throws: SpaceError.alreadyExists(testPubkey("dupe"))) {
      _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("dupe"))
    }
    _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("fresh"))
    #expect(try await space.credential(pubkey: testPubkey("fresh"))?.capabilities == [.seat])
  }

  @Test(arguments: [
    "",
    "phone",
    "ed25519:phone",
    "ed25519:" + Data(repeating: 1, count: 31).base64EncodedString(),
    "ed25519:" + Data(repeating: 1, count: 33).base64EncodedString(),
    "p256:" + Data(repeating: 1, count: 32).base64EncodedString(),
  ])
  func malformedPubkeyNeverEnrollsAndLeavesTheTokenAlive(_ junk: String) async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    await #expect(throws: SpaceError.malformedPubkey(junk)) {
      _ = try await space.addKey(junk, account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    }
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    await #expect(throws: SpaceError.malformedPubkey(junk)) {
      _ = try await space.consumeJoinToken(minted.token, pubkey: junk)
    }
    #expect(try await space.keys(account: owner.id) == [])
    _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("retry"))
    #expect(try await space.credential(pubkey: testPubkey("retry"))?.account == owner.id)
  }

  @Test func malformedOrUnknownTokensAreRejected() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    await #expect(throws: SpaceError.notFound("ac_missing0")) {
      _ = try await space.mintJoinToken(account: AccountID(rawValue: "ac_missing0"), capabilities: [.device], createdBy: nil, lifetime: 600)
    }
    _ = owner
    await #expect(throws: JoinTokenRejected()) {
      _ = try await space.consumeJoinToken(JoinToken(rawValue: "not a token"), pubkey: testPubkey("pk"))
    }
    await #expect(throws: JoinTokenRejected()) {
      _ = try await space.consumeJoinToken(JoinToken(rawValue: "jt_" + String(repeating: "z", count: 32)), pubkey: testPubkey("pk"))
    }
  }

  @Test func theTokenIsStoredOnlyAsAVerifier() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let minted = try await space.mintJoinToken(account: owner.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    let secret = minted.token.rawValue
    try await space.writer.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT * FROM join_tokens")
      #expect(rows.count == 1)
      for row in rows {
        for (column, value) in row {
          #expect(!"\(value)".contains(secret), "join_tokens.\(column) leaks the token")
          #expect(!"\(value)".contains(secret.dropFirst(3)), "join_tokens.\(column) leaks the token body")
        }
      }
    }
    _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("pk"))
  }
}
