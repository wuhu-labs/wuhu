import GRDB
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

enum AliasKind: String, QueryBindable {
  case group
  case person
  case machine
}

@Table("aliases")
struct AliasRow {
  @Column(primaryKey: true) var name: String
  var kind: AliasKind
  var target: String
}

public enum AliasError: Error, Equatable, Sendable {
  case invalid(String)
  case taken(String)
  case memberRequired
}

enum Aliases {
  static func target(_ spelling: String, kind: AliasKind, in db: Database) throws -> String? {
    try AliasRow.where { $0.name.eq(spelling.lowercased()) && $0.kind.eq(kind) }.select(\.target).fetchOne(db)
  }

  static func resolvePerson(_ spelling: String, in db: Database) throws -> String? {
    let id = try target(spelling, kind: .person, in: db) ?? spelling
    if try PersonaRow.find(id).select(\.name).fetchOne(db) != nil { return id }
    return try UserProfileRow.find(id).select(\.principal).fetchOne(db)
  }

  static func requireFree(_ name: String, kind: AliasKind, target: String?, group: GroupID? = nil, in db: Database) throws {
    if let row = try GroupRow.where({ $0.id.eq(name) }).fetchOne(db), kind != .group || row.id != target {
      throw AliasError.taken(name)
    }
    guard let alias = try AliasRow.where({ $0.name.eq(name) }).fetchOne(db), alias.kind != kind || alias.target != target else { return }
    if kind == .machine, alias.kind == .machine, let group,
       let machine = try MachineRow.where({ $0.id.eq(alias.target) }).fetchOne(db), machine.grp == group.rawValue,
       try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM account_keys WHERE account_id = ? UNION ALL SELECT 1 FROM join_tokens WHERE account_id = ?)", arguments: [machine.accountID, machine.accountID])!
    { return }
    throw AliasError.taken(name)
  }

  static func claimMachine(_ name: String, target: String, group: GroupID, in db: Database) throws {
    try requireFree(name, kind: .machine, target: target, group: group, in: db)
    guard let previous = try AliasRow.where({ $0.name.eq(name) }).fetchOne(db), previous.target != target else { return }
    try AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.target.eq(previous.target) }.update { $0.target = #bind(target) }.execute(db)
    try MachineRow.where { $0.id.eq(previous.target) }.update { $0.name = #bind(nil) }.execute(db)
    try db.execute(sql: "UPDATE accounts SET name = NULL WHERE id = (SELECT account_id FROM machines WHERE id = ?)", arguments: [previous.target])
  }
}

extension Space {
  /// All group spellings enter here; access checks and persistence use only ids.
  public func resolveGroup(_ spelling: String) async throws -> GroupID? {
    try await writer.read { db in
      if let row = try GroupRow.where({ $0.id.eq(spelling) }).fetchOne(db), row.removedAt == nil {
        return GroupID(rawValue: row.id)
      }
      guard let alias = try AliasRow.where({ $0.name.eq(spelling.lowercased()) }).fetchOne(db) else { return nil }
      switch alias.kind {
      case .group:
        guard let row = try GroupRow.where({ $0.id.eq(alias.target) }).fetchOne(db), row.removedAt == nil else { return nil }
        return GroupID(rawValue: row.id)
      case .person:
        guard let account = try PersonaRow.find(alias.target).select(\.accountID).fetchOne(db) else { return nil }
        return try Groups.personalGroup(of: AccountID(rawValue: account), in: db)
      case .machine: return nil
      }
    }
  }

  public func createGroup(alias raw: String, owner: AccountID) async throws -> GroupID {
    guard let alias = normalizedLabel(raw, allowing: ["_"], length: 1 ... 63) else { throw AliasError.invalid(raw) }
    let created = SQLiteDateFormat.string(from: dateGen.now)
    let rng = rng
    return try await writer.write { db in
      guard let account = try GroupAccess.accountRow(owner, in: db), account.removedAt == nil, account.kind == "human", !account.guest else {
        throw AliasError.memberRequired
      }
      try Aliases.requireFree(alias, kind: .group, target: nil, in: db)
      let minted = try Allocations.mintSecretCandidateIfUnfrozen(rng, in: db)
      let allocation = try Allocations.draw(.group, createdBy: owner.rawValue, created: created, minted: minted, in: db)
      let group = GroupID(rawValue: allocation.name)
      try GroupRow.insert {
        GroupRow(id: group.rawValue, createdAt: created, visibility: "open", secretsScope: "owner", alias: alias)
      }.execute(db)
      try Groups.grant(.admin, in: group, to: owner, created: created, in: db)
      return group
    }
  }

  public func renameGroup(_ group: GroupID, alias raw: String, by principal: Principal) async throws {
    guard let alias = normalizedLabel(raw, allowing: ["_"], length: 1 ... 63) else { throw AliasError.invalid(raw) }
    try await writer.write { db in
      try GroupAccess.requireAdmin(principal.actor, of: group, acting: principal.group, in: db)
      guard let row = try GroupRow.where({ $0.id.eq(group.rawValue) }).fetchOne(db), row.personalAccount == nil, row.removedAt == nil else {
        throw SpaceError.groupForbidden(group.rawValue)
      }
      try Aliases.requireFree(alias, kind: .group, target: group.rawValue, in: db)
      try GroupRow.where { $0.id.eq(group.rawValue) }.update { $0.alias = #bind(alias) }.execute(db)
    }
  }
}
