import GRDB
import struct SpaceContract.GroupID
import func SpaceContract.normalizedLabel
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
  /// Whether this spelling is its record's current name. Groups and people keep it here; machines keep their current name in their own row.
  var current: Bool = false
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
    return try AliasRow.where { $0.kind.eq(AliasKind.person) && $0.current && $0.target.eq(id) }.select(\.target).fetchOne(db)
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
    cell.resolve(spelling)
  }

  public func createGroup(alias raw: String, name: String? = nil, owner: AccountID) async throws -> GroupID {
    guard let alias = normalizedLabel(raw, allowing: ["_"], length: 1 ... 63) else { throw AliasError.invalid(raw) }
    let name = try name.map(GroupName.checked) ?? alias
    guard cell.canOwnGroup(owner) else { throw AliasError.memberRequired }
    let claim = GroupClaim(alias: alias, name: name, owner: owner, created: SQLiteDateFormat.string(from: dateGen.now))
    let candidate = Allocations.mintSecretCandidate(rng)
    let group = try await worker.call(SpaceCell.ID("space")) { try $0.claim(claim, candidate: candidate) }
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.create(claim) }
    return group
  }

  public func renameGroup(_ group: GroupID, alias raw: String, by principal: Principal) async throws {
    guard let alias = normalizedLabel(raw, allowing: ["_"], length: 1 ... 63) else { throw AliasError.invalid(raw) }
    try requireAdmin(principal.actor, of: group, acting: principal.group)
    try await worker.call(SpaceCell.ID("space")) { try $0.rename(group, alias: alias) }
  }

  public func nameGroup(_ group: GroupID, name raw: String, by principal: Principal) async throws {
    let name = try GroupName.checked(raw)
    try requireAdmin(principal.actor, of: group, acting: principal.group)
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.name(name) }
  }
}
