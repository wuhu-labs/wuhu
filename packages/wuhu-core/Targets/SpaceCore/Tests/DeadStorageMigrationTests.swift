import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct DeadStorageMigrationTests {
  private func atPreviousSchema(_ file: URL) throws {
    try RawDatabase.open(file.path) { db throws in
      try MigrationRunner(
        db: db, log: Logger(label: "migration"), date: .constant(Date(timeIntervalSince1970: 0)),
        baseline: Migrations.baseline, chains: [MigrationChain(.conversations, migrations: [ConversationsMigration001.apply])],
      ).migrate()
    }
  }

  @Test func pushMetadataDropsWithoutLosingDeliveryState() async throws {
    let folder = try ScratchFolder("push-metadata-drop")
    let file = folder.url.appending(path: "space.sqlite")
    try atPreviousSchema(file)
    try RawDatabase.open(file.path) { db throws in
      try db.execute(sql: """
      INSERT INTO accounts (id, kind, created_at, owner) VALUES ('ac_person00', 'human', 'created', 'ac_person00');
      INSERT INTO account_keys (pubkey, account_id, capabilities, created_at, owner) VALUES ('key', 'ac_person00', 'device', 'created', 'ac_person00');
      INSERT INTO personas (name, allocation, pubkey, account_id, created_at, owner) VALUES ('person', 1, 'key', 'ac_person00', 'created', 'ac_person00');
      INSERT INTO push_relay_grants (grant_id, endpoint, token, platform, recipient, device_pubkey, notification_cursor, consecutive_failures, retry_at, created_at, updated_at, owner_account)
        VALUES ('grant', 'relay', 'token', 'ios', 'person', 'key', 17, 2, 'retry', 'created', 'updated', 'ac_person00');
      INSERT INTO web_push_subscriptions (endpoint, recipient, device_pubkey, p256dh, auth, vapid_key_id, notification_cursor, consecutive_failures, retry_at, expires_at, created_at, updated_at, owner_account)
        VALUES ('browser', 'person', 'key', 'p256dh', 'auth', 'vapid', 19, 3, 'retry', 'expiry', 'created', 'updated', 'ac_person00');
      """)
    }
    let upgraded = try Space.open(file: file)
    try await upgraded.close()
    let reopened = try Space.open(file: file)
    try await reopened.close()
    try RawDatabase.open(file.path) { db throws in
      #expect(try db.columns(in: "push_relay_grants") == ["grant_id", "endpoint", "token", "recipient", "device_pubkey", "notification_cursor", "consecutive_failures", "retry_at", "created_at", "owner_account"])
      #expect(try db.columns(in: "web_push_subscriptions") == ["endpoint", "recipient", "device_pubkey", "p256dh", "auth", "vapid_key_id", "notification_cursor", "consecutive_failures", "retry_at", "expires_at", "created_at", "owner_account"])
      #expect(try db.strings("SELECT grant_id || '|' || endpoint || '|' || token || '|' || recipient || '|' || device_pubkey || '|' || notification_cursor || '|' || consecutive_failures || '|' || retry_at || '|' || created_at || '|' || owner_account FROM push_relay_grants") == ["grant|relay|token|person|key|17|2|retry|created|ac_person00"])
      #expect(try db.strings("SELECT endpoint || '|' || recipient || '|' || device_pubkey || '|' || p256dh || '|' || auth || '|' || vapid_key_id || '|' || notification_cursor || '|' || consecutive_failures || '|' || retry_at || '|' || expires_at || '|' || created_at || '|' || owner_account FROM web_push_subscriptions") == ["browser|person|key|p256dh|auth|vapid|19|3|retry|expiry|created|ac_person00"])
      #expect(try db.int("SELECT count(*) FROM grdb_migrations WHERE identifier = 'conversations/0002'") == 1)
      #expect(try db.strings("PRAGMA foreign_key_check") == [])
    }
  }

  @Test func allocationTimeDropsWithoutLosingIdentityOrAttribution() async throws {
    let folder = try ScratchFolder("allocation-time-drop")
    let file = folder.url.appending(path: "space.sqlite")
    try atPreviousSchema(file)
    try RawDatabase.open(file.path) { db throws in
      try db.execute(sql: "INSERT INTO allocations (id, kind, created_by, created_at) VALUES (41, 'person', 'creator', 'created')")
    }
    let upgraded = try Space.open(file: file)
    try await upgraded.close()
    let reopened = try Space.open(file: file)
    try await reopened.close()
    try RawDatabase.open(file.path) { db throws in
      #expect(try db.columns(in: "allocations") == ["id", "kind", "created_by"])
      #expect(try db.strings("SELECT id || '|' || kind || '|' || created_by FROM allocations") == ["41|person|creator"])
      #expect(try db.int("SELECT count(*) FROM grdb_migrations WHERE identifier = 'tenancy/0001'") == 1)
    }
  }
}
