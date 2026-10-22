import DeterministicDependencies
import Foundation
import GRDB
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct AliasTests {
  @Test func creationAllocatesAnOpenGroupAndOnlyItsHumanOwnerAdministersIt() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    let group = try await space.createGroup(alias: "Research_Notes", owner: owner.id)
    #expect(group.rawValue.split(separator: "-").count == 3)
    #expect(try await space.group(group)?.alias == "research_notes")
    #expect(try await space.group(group)?.visibility == .open)
    #expect(try await space.resolveGroup("research_notes") == group)
    #expect(try await space.resolveGroup(group.rawValue) == group)
    #expect(try await space.isHumanAdmin(owner.id, of: group))
    let session = try await space.sessions.createSession(group: .shared, title: "Creator", kind: .agent, createdBy: owner.id.rawValue, model: .test)
    #expect(try await space.role(of: .session(session), in: group, acting: .shared) == .write)
  }

  @Test func onlyLiveHumanMembersCanOwnGroups() async throws {
    let space = try makeSpace()
    let guest = try await space.addAccount(kind: .human, name: "Guest", guest: true)
    let machine = try await space.addMachine(name: "box")
    for owner in [guest.id, machine.account, AccountID(rawValue: "missing")] {
      await #expect(throws: AliasError.memberRequired) { try await space.createGroup(alias: "research", owner: owner) }
    }
    let member = try await space.addAccount(kind: .human, name: "Member")
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE accounts SET removed_at = '2030-01-01T00:00:00Z' WHERE id = ?", arguments: [member.id.rawValue])
    }
    await #expect(throws: AliasError.memberRequired) { try await space.createGroup(alias: "research", owner: member.id) }
  }

  @Test func personAliasesNameTheirPersonalGroupAndKeepResolvingAfterRename() async throws {
    let space = try makeSpace()
    let person = try await space.addAccount(kind: .human, name: "Morgan")
    let key = try await space.addKey(testPubkey("reader"), account: person.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let persona = try await space.adoptPersona(key: key)
    _ = try await space.setUserProfile(principal: persona.name, handle: "morgan", displayName: nil)
    let group = try #require(try await space.personalGroup(of: person.id))
    #expect(try await space.group(group)?.alias == nil)
    #expect(try await space.resolveGroup("morgan") == group)
    _ = try await space.setUserProfile(principal: persona.name, handle: "reader", displayName: nil)
    #expect(try await space.resolveGroup("morgan") == group)
    #expect(try await space.resolveGroup("reader") == group)
  }

  @Test func namespaceAndHistorySpanAllThreeKinds() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    let group = try await space.createGroup(alias: "research", owner: owner.id)
    await #expect(throws: SpaceError.machineNameTaken("research")) { try await space.addMachine(name: "research") }
    await #expect(throws: SpaceError.handleTaken("research")) {
      try await space.setUserProfile(principal: "person", handle: "research", displayName: nil)
    }
    let principal = Principal(actor: .person(persona: "person", account: owner.id), group: group)
    try await space.renameGroup(group, alias: "science", by: principal)
    #expect(try await space.resolveGroup("research") == group)
    #expect(try await space.resolveGroup("science") == group)
    await #expect(throws: AliasError.taken("research")) { try await space.createGroup(alias: "research", owner: owner.id) }
    _ = try await space.setUserProfile(principal: "person", handle: "reader", displayName: nil)
    await #expect(throws: AliasError.taken("reader")) { try await space.createGroup(alias: "reader", owner: owner.id) }
    _ = try await space.addMachine(name: "work_box")
    await #expect(throws: AliasError.taken("work_box")) { try await space.createGroup(alias: "work_box", owner: owner.id) }
    await #expect(throws: AliasError.invalid("with-hyphens")) { try await space.createGroup(alias: "with-hyphens", owner: owner.id) }
    await #expect(throws: (any Error).self) {
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE groups SET alias = 'reader' WHERE id = ?", arguments: [group.rawValue])
      }
    }
    #expect(try await space.group(group)?.alias == "science")
  }

  @Test func groupIDsCannotBeShadowedByAnyAliasKind() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: "Morgan")
    await #expect(throws: AliasError.taken("shared")) { try await space.createGroup(alias: "shared", owner: owner.id) }
    await #expect(throws: SpaceError.machineNameTaken("settings")) { try await space.addMachine(name: "settings") }
    await #expect(throws: SpaceError.handleTaken("settings")) {
      try await space.setUserProfile(principal: "reader", handle: "settings", displayName: nil)
    }
  }

  @Test func legacyNamesWinOverDerivedAliasesAndSuffixesRespectTheGrammar() throws {
    let database = try DatabaseQueue()
    try database.write { db in
      try Migration001.apply(db)
      try Migration002.apply(db)
      try Migration003.apply(db)
      try Migration004.apply(db)
      let long = String(repeating: "a", count: 31)
      try db.execute(sql: """
      INSERT INTO accounts (id, kind, created_at) VALUES ('live', 'machine', '2030-01-01'), ('dead', 'machine', '2030-01-01'), ('odd', 'machine', '2030-01-01');
      INSERT INTO groups (id, created_at) VALUES ('team-space', '2030-01-01'), ('work_box', '2030-01-01');
      INSERT INTO user_profiles (principal, handle, updated_at) VALUES ('owner', 'team_space', '2030-01-01'), ('one', '\(long)-', '2030-01-01'), ('two', '\(long)_', '2030-01-01');
      INSERT INTO machines (id, account_id, name, created_at, grp) VALUES ('mc_old', 'dead', 'work-box', '2030-01-01', 'shared'), ('mc_live', 'live', 'work_box', '2030-01-02', 'shared'), ('mc_odd', 'odd', 'My Laptop (old)', '2030-01-01', 'shared');
      INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES ('live_key', 'live', 'exec_machine', '2030-01-01');
      """)
      try Migration006.apply(db)
      #expect(try String.fetchOne(db, sql: "SELECT handle FROM user_profiles WHERE principal = 'owner'") == "team_space")
      #expect(try String.fetchOne(db, sql: "SELECT alias FROM groups WHERE id = 'team-space'") == "team_space_1")
      #expect(try String.fetchOne(db, sql: "SELECT name FROM machines WHERE id = 'mc_live'") == "work_box_1")
      #expect(try String.fetchOne(db, sql: "SELECT target FROM aliases WHERE name = 'work-box'") == "mc_old")
      #expect(try String.fetchOne(db, sql: "SELECT target FROM aliases WHERE name = 'work_box'") == "mc_live")
      #expect(try Int.fetchOne(db, sql: "SELECT max(length(handle)) FROM user_profiles")! <= 32)
      let odd = try #require(try String.fetchOne(db, sql: "SELECT name FROM machines WHERE id = 'mc_odd'"))
      #expect(MachineName.normalized(odd) == odd)
    }
  }

  @Test func liveMachineNamesTakePrecedenceOverPersonHandles() throws {
    let database = try DatabaseQueue()
    try database.write { db in
      try Migration001.apply(db)
      try Migration002.apply(db)
      try Migration003.apply(db)
      try Migration004.apply(db)
      try Migration005.apply(db)
      try db.execute(sql: """
      INSERT INTO accounts (id, kind, name, created_at) VALUES ('box', 'machine', 'studio', '2030-01-01');
      INSERT INTO user_profiles (principal, handle, updated_at) VALUES ('owner', 'studio', '2030-01-01');
      INSERT INTO machines (id, account_id, name, created_at, grp) VALUES ('mc_box', 'box', 'studio', '2030-01-01', 'shared');
      INSERT INTO account_keys (pubkey, account_id, capabilities, created_at) VALUES ('live_key', 'box', 'exec_machine', '2030-01-01');
      """)
      try Migration006.apply(db)
      #expect(try String.fetchOne(db, sql: "SELECT name FROM machines WHERE id = 'mc_box'") == "studio")
      #expect(try String.fetchOne(db, sql: "SELECT name FROM accounts WHERE id = 'box'") == "studio")
      #expect(try String.fetchOne(db, sql: "SELECT handle FROM user_profiles WHERE principal = 'owner'") == "studio_1")
      #expect(try String.fetchOne(db, sql: "SELECT target FROM aliases WHERE name = 'studio'") == "mc_box")
      #expect(try String.fetchOne(db, sql: "SELECT target FROM aliases WHERE name = 'studio_1'") == "owner")
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  @Test func migrationNormalizesAndDisambiguatesRealLegacyLabels() throws {
    let database = try DatabaseQueue()
    try database.write { db in
      try Migration001.apply(db)
      try Migration002.apply(db)
      try Migration003.apply(db)
      try Migration004.apply(db)
      try db.execute(sql: """
      INSERT INTO accounts (id, kind, name, created_at) VALUES ('human', 'human', 'Human', '2030-01-01'), ('box', 'machine', 'Box', '2030-01-01'), ('other_box', 'machine', 'Other', '2030-01-01'), ('third_box', 'machine', 'Third', '2030-01-01');
      INSERT INTO groups (id, created_at, personal_account) VALUES ('personal', '2030-01-01', 'human'), ('team', '2030-01-01', NULL);
      INSERT INTO user_profiles (principal, handle, updated_at) VALUES ('person', 'team', '2030-01-01');
      INSERT INTO machines (id, account_id, name, created_at, grp) VALUES ('mc_one', 'box', 'team', '2030-01-01', 'shared'), ('mc_two', 'other_box', 'box-a', '2030-01-01', 'shared'), ('mc_three', 'third_box', 'box_a', '2030-01-01', 'shared');
      """)
      try Migration006.apply(db)
      #expect(try String.fetchOne(db, sql: "SELECT alias FROM groups WHERE id = 'shared'") == "shared")
      #expect(try String.fetchOne(db, sql: "SELECT alias FROM groups WHERE id = 'personal'") == nil)
      #expect(try String.fetchOne(db, sql: "SELECT handle FROM user_profiles WHERE principal = 'person'") == "team_1")
      #expect(try String.fetchOne(db, sql: "SELECT target FROM aliases WHERE name = 'team'") == "person")
      #expect(try String.fetchOne(db, sql: "SELECT name FROM machines WHERE id = 'mc_one'") == "team_2")
      #expect(try Int.fetchOne(db, sql: "SELECT count(DISTINCT name) FROM machines") == 3)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM machines WHERE name LIKE '%-%'") == 0)
      #expect(try String.fetchOne(db, sql: "SELECT target FROM aliases WHERE name = 'box-a'") == "mc_two")
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }
}
