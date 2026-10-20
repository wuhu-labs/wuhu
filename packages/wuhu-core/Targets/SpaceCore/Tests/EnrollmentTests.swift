import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import Scratch
@testable import SpaceCore
import Synchronization
import Testing

@Suite(.deterministicDependencies)
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
    await #expect(throws: JoinTokenRejected()) { _ = try await space.consumeJoinToken(minted.token, pubkey: testPubkey("pk")) }
    #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM join_token_receipts") } == 0)

    let machine = try await space.addMachine(name: "box", group: .shared)
    let rekey = try await space.mintJoinToken(account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600)
    let machineSecret = rekey.token.rawValue
    _ = try await space.consumeJoinToken(rekey.token, pubkey: testPubkey("box"))
    try await space.writer.read { db in
      let receipts = try Row.fetchAll(db, sql: "SELECT * FROM join_token_receipts")
      #expect(receipts.count == 1)
      for row in receipts {
        #expect(row["token_hash"] as String == Space.credentialDigest(machineSecret))
        for (column, value) in row {
          #expect(!"\(value)".contains(machineSecret.dropFirst(3)), "join_token_receipts.\(column) leaks the token body")
        }
      }
    }
    await #expect(throws: SpaceError.self) { _ = try await space.query("SELECT * FROM join_token_receipts") }
  }

  // A rollback to a server that predates receipts runs only the credential
  // statements it already had; the receipt table must never stand in their way.
  @Test func receiptsNeverBlockTheCredentialStatementsAnOlderServerRuns() async throws {
    let scratch = try ScratchFolder("receipt-rollback")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: file)
    let owner = try await space.addMachine(name: "box", group: .shared).account
    let first = try await space.mintJoinToken(account: owner, capabilities: [.execMachine], createdBy: nil, lifetime: 600)
    let second = try await space.mintJoinToken(account: owner, capabilities: [.execMachine], createdBy: nil, lifetime: 600)
    _ = try await space.consumeJoinToken(first.token, pubkey: testPubkey("one"))
    _ = try await space.consumeJoinToken(second.token, pubkey: testPubkey("two"))
    #expect(try await space.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM join_token_receipts") } == 2)
    let reopened = try Space.open(file: file)
    try await reopened.writer.write { db in
      try db.execute(sql: "DELETE FROM account_keys WHERE pubkey = ?", arguments: [testPubkey("one")])
      try db.execute(sql: "DELETE FROM account_keys WHERE account_id = ?", arguments: [owner.rawValue])
      try db.execute(
        sql: "INSERT INTO account_keys (pubkey, account_id, capabilities, created_by, created_at, expires_at) VALUES (?, ?, ?, NULL, ?, NULL)",
        arguments: [testPubkey("one"), owner.rawValue, "exec-machine", "2026-10-15T00:00:00.000Z"],
      )
    }
    #expect(try await reopened.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM join_token_receipts") } == 0)
    #expect(try await reopened.credential(pubkey: testPubkey("one"))?.account == owner)
  }
}
