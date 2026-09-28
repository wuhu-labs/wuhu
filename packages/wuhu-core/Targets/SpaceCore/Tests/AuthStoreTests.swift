import Foundation
@testable import SpaceCore
import Testing

@Suite
struct AuthStoreTests {
  @Test func eachAddCreatesADistinctAccount() async throws {
    let space = try makeSpace()
    let first = try await space.addAccount(kind: .human, name: "alice")
    let second = try await space.addAccount(kind: .human, name: "alice")
    #expect(first.id != second.id)
    #expect(AccountID.isValid(first.id.rawValue))
    let listed = try await space.accounts()
    #expect(Set(listed.map(\.id)) == [first.id, second.id])
  }

  @Test func ownerIsAReservedAccountNameInAnyCasing() async throws {
    let space = try makeSpace()
    for name in ["owner", "Owner", "OWNER", "oWnEr"] {
      await #expect(throws: SpaceError.reservedAccountName(name)) {
        _ = try await space.addAccount(kind: .human, name: name)
      }
    }
    _ = try await space.addAccount(kind: .human, name: "owner-adjacent")
    #expect(try await space.accounts().count == 1)
  }

  @Test func accountRoundTrips() async throws {
    let space = try makeSpace()
    let human = try await space.addAccount(kind: .human, name: "alice")
    let affiliate = try await space.addAccount(kind: .space, name: nil)
    #expect(try await space.account(human.id) == human)
    #expect(try await space.account(affiliate.id) == affiliate)
    #expect(human.kind == .human)
    #expect(affiliate.kind == .space)
    #expect(affiliate.name == nil)
    #expect(human.createdAt == fixedDate)
    #expect(try await space.account(AccountID(rawValue: "ac_missing0")) == nil)
  }

  @Test func keyRoundTrips() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let enroller = try await space.addAccount(kind: .human, name: nil)
    let expiry = fixedDate.addingTimeInterval(3600)
    let key = try await space.addKey(
      testPubkey("laptop"),
      account: owner.id,
      capabilities: [.device, .seat, .execMachine],
      createdBy: enroller.id,
      expiresAt: expiry,
    )
    #expect(try await space.credential(pubkey: testPubkey("laptop")) == key)
    #expect(key.capabilities == [.device, .seat, .execMachine])
    #expect(key.createdBy == enroller.id)
    #expect(key.expiresAt == expiry)
    #expect(try await space.keys(account: owner.id) == [key])
    #expect(try await space.keys(account: enroller.id) == [])
  }

  @Test func keyRequiresAccountAndUniquePubkey() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    await #expect(throws: SpaceError.notFound("ac_missing0")) {
      _ = try await space.addKey(testPubkey("pk"), account: AccountID(rawValue: "ac_missing0"), capabilities: [.device], createdBy: nil, expiresAt: nil)
    }
    _ = try await space.addKey(testPubkey("pk"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    await #expect(throws: SpaceError.alreadyExists(testPubkey("pk"))) {
      _ = try await space.addKey(testPubkey("pk"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    }
  }

  @Test func expiredKeyIsNoCredentialButStaysListed() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(testPubkey("old"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: fixedDate.addingTimeInterval(-1))
    #expect(try await space.credential(pubkey: testPubkey("old")) == nil)
    #expect(try await space.keys(account: owner.id).map(\.pubkey) == [testPubkey("old")])
  }

  @Test func expiryAtExactlyNowIsExpiredInBothPaths() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(testPubkey("edge"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: fixedDate)
    #expect(try await space.credential(pubkey: testPubkey("edge")) == nil)
    let readSession = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate)
    #expect(try await space.account(readSession: readSession, in: .shared) == nil)
  }

  @Test func corruptKeyExpiryRefusesTheCredential() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(testPubkey("poisoned"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: fixedDate.addingTimeInterval(-3600))
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE account_keys SET expires_at = '2020-01-01 00:00:00' WHERE pubkey = ?", arguments: [testPubkey("poisoned")])
    }
    #expect(try await space.credential(pubkey: testPubkey("poisoned")) == nil)
  }

  // A malformed key row fails the request closed — never a crash, never an
  // auto-delete: the row stays put as evidence.
  @Test func corruptKeyCapabilityRefusesTheCredentialKeepsTheRowAndWarns() async throws {
    let logs = RecordedLogs()
    let space = try makeSpace(log: logs.logger)
    let owner = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(testPubkey("junk"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE account_keys SET capabilities = 'device warp-drive' WHERE pubkey = ?", arguments: [testPubkey("junk")])
    }
    #expect(try await space.credential(pubkey: testPubkey("junk")) == nil)
    let warnings = logs.all.filter { $0.level == .warning }
    #expect(warnings.count == 1)
    #expect(warnings.first?.metadata["pubkey"] == testPubkey("junk"))
    #expect(warnings.first?.metadata["reason"]?.contains("warp-drive") == true)
    let survived = try await space.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM account_keys WHERE pubkey = ?", arguments: [testPubkey("junk")])
    }
    #expect(survived == 1)
    await #expect(throws: (any Error).self) {
      _ = try await space.keys(account: owner.id)
    }
  }

  @Test func corruptReadSessionExpiryRefusesTheToken() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let token = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(-3600))
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE read_sessions SET expires_at = 'corrupted 2020-01-01'")
    }
    await #expect(throws: (any Error).self) {
      _ = try await space.account(readSession: token, in: .shared)
    }
  }

  @Test func schemaRefusesUnknownAccountKind() async throws {
    let space = try makeSpace()
    _ = try await space.addAccount(kind: .human, name: nil)
    await #expect(throws: (any Error).self) {
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE accounts SET kind = 'alien'")
      }
    }
  }

  @Test func removedKeyIsGone() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(testPubkey("pk"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    try await space.removeKey(pubkey: testPubkey("pk"))
    #expect(try await space.credential(pubkey: testPubkey("pk")) == nil)
    #expect(try await space.keys(account: owner.id) == [])
    await #expect(throws: SpaceError.notFound(testPubkey("pk"))) {
      try await space.removeKey(pubkey: testPubkey("pk"))
    }
  }

  @Test func readSessionRoundTripsAsAnOpaqueToken() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let token = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    #expect(ReadSessionToken.isValid(token.rawValue))
    #expect(try await space.account(readSession: token, in: .shared) == owner.id)
    #expect(try await space.account(readSession: ReadSessionToken(rawValue: "rs_" + String(repeating: "z", count: 32)), in: .shared) == nil)
    #expect(try await space.account(readSession: ReadSessionToken(rawValue: "not a token"), in: .shared) == nil)
    await #expect(throws: SpaceError.notFound("ac_missing0")) {
      _ = try await space.createReadSession(account: AccountID(rawValue: "ac_missing0"), group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    }
  }

  @Test func expiredOrDeletedReadSessionIsNoReadSession() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let expired = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(-1))
    #expect(try await space.account(readSession: expired, in: .shared) == nil)
    let live = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    try await space.deleteReadSession(live)
    #expect(try await space.account(readSession: live, in: .shared) == nil)
  }

  @Test func mintingAReadSessionPrunesTheAccountsExpiredRows() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let bystander = try await space.addAccount(kind: .human, name: "bystander")
    _ = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(-1))
    _ = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate)
    let bystanderExpired = try await space.createReadSession(account: bystander.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(-1))

    _ = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    let remaining = try await space.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM read_sessions WHERE account_id = ?", arguments: [owner.id.rawValue])
    }
    // The two dead owner rows are swept; the fresh one is all that survives.
    #expect(remaining == 1)
    // Pruning is scoped to the minting account: a bystander's dead row stays.
    let bystanderRows = try await space.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM read_sessions WHERE token_hash = ?", arguments: [Space.credentialDigest(bystanderExpired.rawValue)])
    }
    #expect(bystanderRows == 1)
  }

  @Test func mintingSupersedesTheNamedReadSession() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: nil)
    let first = try await space.createReadSession(account: owner.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    let second = try await space.createReadSession(
      account: owner.id,
      group: .shared,
      expiresAt: fixedDate.addingTimeInterval(3600),
      supersedes: first,
    )
    #expect(try await space.account(readSession: first, in: .shared) == nil)
    #expect(try await space.account(readSession: second, in: .shared) == owner.id)
    let rows = try await space.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM read_sessions WHERE account_id = ?", arguments: [owner.id.rawValue])
    }
    #expect(rows == 1)
  }

  @Test func adminIsAnAccountFlagOffByDefault() async throws {
    let space = try makeSpace()
    let plain = try await space.addAccount(kind: .human, name: nil)
    let admin = try await space.addAccount(kind: .human, name: nil, admin: true)
    #expect(plain.isAdmin == false)
    #expect(admin.isAdmin == true)
    #expect(try await space.hasAdminAccount())
    #expect(try await space.account(plain.id)?.isAdmin == false)
    #expect(try await space.account(admin.id)?.isAdmin == true)
  }

  @Test func setAdminGrantsRevokesAndGuardsTheLastAdmin() async throws {
    let space = try makeSpace()
    let first = try await space.addAccount(kind: .human, name: nil, admin: true)
    let second = try await space.addAccount(kind: .human, name: nil)

    await #expect(throws: SpaceError.lastAdmin(first.id.rawValue)) {
      _ = try await space.setAdmin(first.id, admin: false)
    }
    #expect(try await space.setAdmin(second.id, admin: true).isAdmin == true)
    _ = try await space.setAdmin(first.id, admin: false)
    #expect(try await space.account(first.id)?.isAdmin == false)
    await #expect(throws: SpaceError.notFound("ac_missing0")) {
      _ = try await space.setAdmin(AccountID(rawValue: "ac_missing0"), admin: true)
    }
  }

  @Test func removeAccountKillsCredentialsAndKeepsAttribution() async throws {
    let space = try makeSpace()
    _ = try await space.addAccount(kind: .human, name: "root", admin: true)
    let victim = try await space.addAccount(kind: .human, name: "victim")
    _ = try await space.addKey(testPubkey("victim"), account: victim.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let readSession = try await space.createReadSession(account: victim.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    let invite = try await space.mintJoinToken(account: victim.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    let persona = try await space.mintPersona(key: try #require(try await space.credential(pubkey: testPubkey("victim"))))

    let removed = try await space.removeAccount(victim.id)
    #expect(removed.keys == 1)
    #expect(removed.readSessions == 1)
    #expect(try await space.credential(pubkey: testPubkey("victim")) == nil)
    #expect(try await space.account(readSession: readSession, in: .shared) == nil)
    await #expect(throws: JoinTokenRejected.self) {
      _ = try await space.consumeJoinToken(invite.token, pubkey: testPubkey("latecomer"))
    }

    // The tombstone: gone from the roster, resolvable for attribution.
    #expect(!(try await space.accounts().map(\.id).contains(victim.id)))
    let tombstone = try #require(try await space.account(victim.id))
    #expect(tombstone.removedAt != nil)
    #expect(try await space.persona(named: persona.name)?.account == victim.id)

    // Removed means gone for every credential-granting path.
    await #expect(throws: SpaceError.notFound(victim.id.rawValue)) {
      _ = try await space.addKey(testPubkey("return"), account: victim.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    }
    await #expect(throws: SpaceError.notFound(victim.id.rawValue)) {
      _ = try await space.mintJoinToken(account: victim.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    }
    await #expect(throws: SpaceError.notFound(victim.id.rawValue)) {
      _ = try await space.removeAccount(victim.id)
    }
  }

  @Test func removeAccountRefusesTheLastAdmin() async throws {
    let space = try makeSpace()
    let admin = try await space.addAccount(kind: .human, name: nil, admin: true)
    _ = try await space.addAccount(kind: .human, name: nil)
    await #expect(throws: SpaceError.lastAdmin(admin.id.rawValue)) {
      _ = try await space.removeAccount(admin.id)
    }
  }

  @Test func resetWipesOnlyThatAccountsCredentials() async throws {
    let space = try makeSpace()
    let victim = try await space.addAccount(kind: .human, name: "victim")
    let bystander = try await space.addAccount(kind: .human, name: "bystander")
    _ = try await space.addKey(testPubkey("victim-1"), account: victim.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    _ = try await space.addKey(testPubkey("victim-2"), account: victim.id, capabilities: [.device, .seat], createdBy: nil, expiresAt: nil)
    _ = try await space.addKey(testPubkey("bystander"), account: bystander.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    _ = try await space.createReadSession(account: victim.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    let bystanderReadSession = try await space.createReadSession(account: bystander.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))

    let removed = try await space.resetCredentials(account: victim.id)
    #expect(removed.keys == 2)
    #expect(removed.readSessions == 1)
    #expect(try await space.keys(account: victim.id) == [])
    #expect(try await space.account(victim.id) == victim)
    #expect(try await space.keys(account: bystander.id).map(\.pubkey) == [testPubkey("bystander")])
    #expect(try await space.account(readSession: bystanderReadSession, in: .shared) == bystander.id)
    await #expect(throws: SpaceError.notFound("ac_missing0")) {
      _ = try await space.resetCredentials(account: AccountID(rawValue: "ac_missing0"))
    }
  }
}
