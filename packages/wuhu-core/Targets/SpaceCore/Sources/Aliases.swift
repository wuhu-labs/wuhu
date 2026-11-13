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
  /// Whether this spelling is its record's current name. Every kind keeps it here, in the row it marks `current`.
  var current: Bool = false
}

public enum AliasError: Error, Equatable, Sendable {
  case invalid(String)
  case taken(String)
  case memberRequired
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
