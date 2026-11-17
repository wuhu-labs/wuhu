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
import Wuwei

@Suite(.deterministicDependencies) struct MachineKeyMigrationTests {
  private func atPreviousSchema(_ file: URL) throws {
    _ = try WuweiDatabase(path: file.path, log: Logger(label: "migration"))
    try RawDatabase.open(file.path) { db throws in
      try MigrationRunner(
        db: db, log: Logger(label: "migration"), date: .constant(Date(timeIntervalSince1970: 0)),
        baseline: Migrations.baseline, chains: Migrations.chains.map { $0.family == .machines ? MigrationChain(.machines) : $0 },
      ).migrate()
    }
  }

  @Test func eachMachineKeepsItsLiveKeyAndPendingTokenAndItsAccountGoes() async throws {
    let folder = try ScratchFolder("machine-key-migration")
    let file = folder.url.appending(path: "space.sqlite")
    try atPreviousSchema(file)
    try RawDatabase.open(file.path) { db throws in
      try db.execute(sql: """
      INSERT INTO accounts (id, kind, created_at, owner) VALUES
        ('ac_person01', 'human', '2026-01-01T00:00:00.000Z', 'ac_person01'),
        ('ac_keyed001', 'machine', '2026-01-01T00:00:00.000Z', 'ac_keyed001'),
        ('ac_pending1', 'machine', '2026-01-01T00:00:00.000Z', 'ac_pending1'),
        ('ac_bare0001', 'machine', '2026-01-01T00:00:00.000Z', 'ac_bare0001');
      INSERT INTO machines (id, account_id, created_at, grp) VALUES
        ('mc_keyed001', 'ac_keyed001', '2026-01-02T00:00:00.000Z', 'shared'),
        ('mc_pending1', 'ac_pending1', '2026-01-03T00:00:00.000Z', 'shared'),
        ('mc_bare0001', 'ac_bare0001', '2026-01-04T00:00:00.000Z', 'shared');
      INSERT INTO machine_v2_members (machine_id, grp, created_at) VALUES
        ('mc_keyed001', 'shared', '2026-01-02T00:00:00.000Z'), ('mc_pending1', 'shared', '2026-01-03T00:00:00.000Z'), ('mc_bare0001', 'shared', '2026-01-04T00:00:00.000Z');
      INSERT INTO account_keys (pubkey, account_id, capabilities, created_by, created_at, expires_at, owner) VALUES
        ('person-key', 'ac_person01', 'device', 'ac_keyed001', '2026-01-01T00:00:00.000Z', NULL, 'ac_person01'),
        ('expired-key', 'ac_keyed001', 'exec-machine', NULL, '2026-01-05T00:00:00.000Z', '2000-01-01T00:00:00.000Z', 'ac_keyed001'),
        ('box-key', 'ac_keyed001', 'exec-machine', 'ac_person01', '2026-01-02T00:00:00.000Z', NULL, 'ac_keyed001'),
        ('login-key', 'ac_bare0001', 'device', NULL, '2026-01-04T00:00:00.000Z', NULL, 'ac_bare0001');
      INSERT INTO join_tokens (token_hash, account_id, capabilities, created_at, expires_at, grp, owner) VALUES
        ('live-hash', 'ac_pending1', 'exec-machine', '2026-01-03T00:00:00.000Z', '2999-01-01T00:00:00.000Z', 'shared', 'ac_pending1'),
        ('dead-hash', 'ac_bare0001', 'exec-machine', '2026-01-04T00:00:00.000Z', '2000-01-01T00:00:00.000Z', 'shared', 'ac_bare0001');
      INSERT INTO join_token_receipts (token_hash, pubkey, expires_at, owner) VALUES ('used-hash', 'box-key', '2999-01-01T00:00:00.000Z', 'ac_keyed001');
      INSERT INTO personas (name, allocation, pubkey, account_id, created_at, owner) VALUES ('bare', 7, 'login-key', 'ac_bare0001', '2026-01-04T00:00:00.000Z', 'ac_bare0001');
      INSERT INTO devices (id, account_id, pubkey, installation, kind, name, machine_id, created_at, last_seen_at, owner) VALUES
        ('dv_person1', 'ac_person01', 'person-key', 'app', 'mac', 'Mac', 'mc_keyed001', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', 'ac_person01'),
        ('dv_bare001', 'ac_bare0001', 'login-key', 'web', 'web', 'Login', NULL, '2026-01-04T00:00:00.000Z', '2026-01-04T00:00:00.000Z', 'ac_bare0001');
      INSERT INTO aliases (name, kind, target, current) VALUES ('keyed', 'machine', 'mc_keyed001', 1), ('ghost', 'machine', 'mc_gone0001', 1);
      INSERT INTO wuwei_addressable (address, holder, fence, expires_at) VALUES ('PersonCell/ac_keyed001', 'old', 1, 0), ('PersonCell/ac_person01', 'old', 1, 0);
      INSERT INTO wuwei_mail (recipient, payload) VALUES
        ('PersonCell/ac_pending1', CAST('{"resetCredentials":{}}' AS BLOB)),
        ('PersonCell/ac_person01', CAST('{"machineAccount":{}}' AS BLOB)),
        ('MachineCell/mc_bare0001', CAST('{"create":{}}' AS BLOB)),
        ('MachineCell/mc_keyed001', CAST('{"closeBoxes":{}}' AS BLOB)),
        ('MachineCell/mc_keyed001', CAST('{"kill":{}}' AS BLOB));
      """)
    }
    let upgraded = try Space.open(file: file)
    #expect(try await upgraded.accounts().map(\.id.rawValue) == ["ac_person01"])
    try await upgraded.close()
    try RawDatabase.open(file.path) { db throws in
      #expect(try db.columns(in: "machines") == ["id", "created_at", "grp", "scope", "pubkey", "enrolled_at", "enrolled_by", "token_hash", "token_expires_at"])
      #expect(try db.strings("SELECT id || '|' || created_at || '|' || ifnull(pubkey, '-') || '|' || ifnull(enrolled_at, '-') || '|' || ifnull(enrolled_by, '-') || '|' || ifnull(token_hash, '-') FROM machines ORDER BY id") == [
        "mc_bare0001|2026-01-04T00:00:00.000Z|-|-|-|-",
        "mc_keyed001|2026-01-02T00:00:00.000Z|box-key|2026-01-02T00:00:00.000Z|ac_person01|-",
        "mc_pending1|2026-01-03T00:00:00.000Z|-|-|-|live-hash",
      ])
      #expect(try db.strings("SELECT pubkey || '|' || ifnull(created_by, '-') FROM account_keys") == ["person-key|-"])
      #expect(try db.strings("SELECT token_hash FROM join_tokens") == [])
      #expect(try db.strings("SELECT name FROM personas") == [])
      #expect(try db.strings("SELECT id || '|' || machine_id FROM devices") == ["dv_person1|mc_keyed001"])
      #expect(try db.strings("SELECT name FROM aliases WHERE kind = 'machine'") == ["keyed"])
      #expect(try db.strings("SELECT name FROM sqlite_master WHERE name = 'join_token_receipts'") == [])
      #expect(try db.strings("SELECT address FROM wuwei_addressable WHERE address LIKE 'PersonCell/%'") == ["PersonCell/ac_person01"])
      #expect(try db.strings("SELECT recipient || CAST(payload AS TEXT) FROM wuwei_mail ORDER BY id") == [
        "MachineCell/mc_keyed001{\"kill\":{}}",
      ])
      #expect(try db.int("SELECT count(*) FROM grdb_migrations WHERE identifier = 'machines/0001'") == 1)
      #expect(try db.strings("PRAGMA foreign_key_check") == [])
    }
    let reopened = try Space.open(file: file).registeringMachines()
    #expect(try await reopened.machineFamily.machine(pubkey: "box-key")?.rawValue == "mc_keyed001")
    #expect(try await reopened.machineFamily.machine(named: "keyed")?.id.rawValue == "mc_keyed001")
    #expect(try await reopened.machineFamily.machines().map(\.id.rawValue).sorted() == ["mc_bare0001", "mc_keyed001", "mc_pending1"])
    try await reopened.close()
  }
}
