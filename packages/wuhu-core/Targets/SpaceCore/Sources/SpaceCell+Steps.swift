import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei

extension SpaceCell {
  /// Reserves `claim.alias`, draws the group's id and mails the newborn its claim, in one step: a crash after the claim cannot leave an alias naming nothing.
  mutating func claim(_ claim: GroupClaim, candidate: [UInt8]) throws -> GroupID {
    try requireFree(claim.alias, kind: .group, target: nil)
    let name = try draw(.group, createdBy: claim.owner.rawValue, created: claim.created, candidate: candidate).name
    let group = GroupID(rawValue: name)
    try db.execute(AliasRow.insert { AliasRow(name: claim.alias, kind: .group, target: group.rawValue, current: true) })
    ctx.send(GroupCell.ID(group.rawValue)).create(claim)
    return group
  }

  /// Marks `alias` the group's current one; every spelling it ever had stays reserved.
  mutating func rename(_ group: GroupID, alias: String) throws {
    guard let row = db.rows(GroupRow.where { $0.id.eq(group.rawValue) }).first, row.removedAt == nil else {
      throw SpaceError.groupForbidden(group.rawValue)
    }
    try setCurrentAlias(alias, kind: .group, target: group.rawValue)
  }

  mutating func renamePerson(_ principal: String, handle: String) throws {
    try setCurrentAlias(handle, kind: .person, target: principal)
  }

  mutating func setCurrentAlias(_ alias: String, kind: AliasKind, target: String) throws {
    try requireFree(alias, kind: kind, target: target)
    try db.execute(AliasRow.where { $0.kind.eq(kind) && $0.target.eq(target) }.update { $0.current = #bind(false) })
    try db.execute(AliasRow.insert {
      AliasRow(name: alias, kind: kind, target: target, current: true)
    } onConflict: {
      ($0.name)
    } doUpdate: {
      $0.current = $1.current
    })
  }

  func requireFree(_ alias: String, kind: AliasKind, target: String?) throws {
    if let existing = db.rows(GroupRow.where { $0.id.eq(alias) }).first, kind != .group || existing.id != target { throw AliasError.taken(alias) }
    guard let held = db.rows(AliasRow.where { $0.name.eq(alias) }).first else { return }
    guard held.kind == kind, held.target == target else { throw AliasError.taken(alias) }
  }
}
