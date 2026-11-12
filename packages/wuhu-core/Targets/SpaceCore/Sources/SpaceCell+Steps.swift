import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei

extension SpaceCell {
  /// Reserves `claim.alias`, draws the group's id and mails the newborn its claim, in one step: a crash after the claim cannot leave an alias naming nothing.
  mutating func claim(_ claim: GroupClaim, candidate: [UInt8]) throws -> GroupID {
    try requireFree(claim.alias, for: nil)
    let name = try draw(.group, createdBy: claim.owner.rawValue, created: claim.created, candidate: candidate).name
    let group = GroupID(rawValue: name)
    try db.execute(AliasRow.insert { AliasRow(name: claim.alias, kind: .group, target: group.rawValue, current: true) })
    ctx.send(GroupCell.ID(group.rawValue)).create(claim)
    return group
  }

  /// Marks `alias` the group's current one; every spelling it ever had stays reserved.
  mutating func rename(_ group: GroupID, alias: String) throws {
    guard let row = db.rows(GroupRow.where { $0.id.eq(group.rawValue) }).first, row.personalAccount == nil, row.removedAt == nil else {
      throw SpaceError.groupForbidden(group.rawValue)
    }
    try requireFree(alias, for: group)
    try db.execute(AliasRow.where { $0.kind.eq(AliasKind.group) && $0.target.eq(group.rawValue) }.update { $0.current = #bind(false) })
    try db.execute(AliasRow.insert {
      AliasRow(name: alias, kind: .group, target: group.rawValue, current: true)
    } onConflict: {
      ($0.name)
    } doUpdate: {
      $0.current = $1.current
    })
  }

  /// An alias is free for `group` when no other group has it as an id and nobody else holds it; a group may rename itself to its own id.
  private func requireFree(_ alias: String, for group: GroupID?) throws {
    if let existing = db.rows(GroupRow.where { $0.id.eq(alias) }).first, existing.id != group?.rawValue { throw AliasError.taken(alias) }
    guard let held = db.rows(AliasRow.where { $0.name.eq(alias) }).first else { return }
    guard held.kind == .group, held.target == group?.rawValue else { throw AliasError.taken(alias) }
  }
}
