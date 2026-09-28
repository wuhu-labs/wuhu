#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import struct SpaceContract.GroupID
import struct SpaceFS.SpacePath

/// A group's instruction layer: its `/AGENTS.md` and `/.agents/skills/**`. In
/// `shared` it is the space-wide layer, and `/models.json` rides with it.
public enum GroupLayer {
  public static func covers(_ path: SpacePath, in group: GroupID) -> Bool {
    let components = path.components
    if components == ["AGENTS.md"] { return true }
    if components.first == ".agents", components.count == 1 || components[1] == "skills" { return true }
    return group == .shared && components == ["models.json"]
  }

  static func refuseWrite(_ path: SpacePath, in group: GroupID, by actor: Actor, in db: Database) throws {
    guard covers(path, in: group), try !admits(actor, to: group, in: db) else { return }
    throw SpaceError.layerForbidden(path: path.rawValue, group: group.rawValue)
  }

  static func admits(_ actor: Actor, to group: GroupID, in db: Database) throws -> Bool {
    switch actor {
    case .anonymous:
      return true
    case let .session(id):
      if group != .shared { return try Sessions.group(of: id.rawValue, in: db) == group }
      return try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS (SELECT 1 FROM sessions WHERE id = ? AND grp = 'shared' AND kind = 'agent' AND parent IS NULL AND lifecycle = 'live')",
        arguments: [id.rawValue],
      ) ?? false
    case let .person(_, account):
      if group == .shared { return try Groups.isHumanAdmin(account, of: .shared, in: db) }
      return try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM group_members WHERE grp = ? AND account_id = ?)",
        arguments: [group.rawValue, account.rawValue],
      ) ?? false
    }
  }
}

extension Space {
  /// Writing a group's layer: in `shared` an admin of `shared`, elsewhere a
  /// member (a session of the group, or a member person). The --dev seat is
  /// unrestricted.
  public func refuseLayerWrite(_ path: SpacePath, in group: GroupID, by actor: Actor) async throws {
    try await writer.read { db in try GroupLayer.refuseWrite(path, in: group, by: actor, in: db) }
  }

  /// Turns the space-wide layer on or off for `group`'s sessions. A live
  /// session's prompt takes it at its next compaction or Start over.
  public func setSpaceLayer(_ group: GroupID, on: Bool) async throws {
    try await writer.write { db in
      try db.execute(
        sql: "UPDATE groups SET space_layer = ? WHERE id = ? AND removed_at IS NULL", arguments: [on, group.rawValue],
      )
      guard db.changesCount > 0 else { throw SpaceError.notFound(group.rawValue) }
      try db.execute(sql: "UPDATE group_epoch SET n = n + 1 WHERE id = 1")
      try db.execute(
        sql: "DELETE FROM session_scope_context WHERE session_id IN (SELECT id FROM sessions WHERE grp = ?)",
        arguments: [group.rawValue],
      )
    }
  }

  public func spaceLayer(of group: GroupID) async throws -> Bool {
    try await writer.read { db in
      try Bool.fetchOne(db, sql: "SELECT space_layer FROM groups WHERE id = ?", arguments: [group.rawValue]) ?? true
    }
  }

  /// The group a new top-level agent lands in: `requested`, else the
  /// creator's; the creator's group must read it.
  public func homeGroup(_ requested: GroupID?, creator: GroupID) async throws -> GroupID {
    guard let requested, requested != creator else { return creator }
    guard try await groupExists(requested), try await reads(creator).contains(requested) else {
      throw SpaceError.groupForbidden(requested.rawValue)
    }
    return requested
  }
}
