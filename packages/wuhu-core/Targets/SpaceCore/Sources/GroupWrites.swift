#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import struct SpaceContract.GroupID
import struct SpaceFS.SpacePath

/// Which group files a write is judged against: a group's instructions (its
/// `/AGENTS.md` and `/.agents/skills/**`), and the settings group, which only
/// space admins write.
enum GroupWrites {
  static func isInstructions(_ path: SpacePath) -> Bool {
    let components = path.components
    if components == ["AGENTS.md"] { return true }
    if components.first == ".agents", components.count == 1 || components[1] == "skills" { return true }
    return false
  }

  static func refuseWrite(_ path: SpacePath, in group: GroupID, by actor: Actor, in db: Database) throws {
    if case .anonymous = actor { return }
    let admitted = if group == .settings {
      try settingsAdmin(actor, in: db)
    } else {
      isInstructions(path) ? try admits(actor, to: group, in: db) : true
    }
    guard admitted else { throw SpaceError.forbiddenWrite(path: path.rawValue, group: group.rawValue) }
  }

  /// A group's instructions take its members (or an admin of it); every group
  /// follows the same rule.
  static func admits(_ actor: Actor, to group: GroupID, in db: Database) throws -> Bool {
    switch actor {
    case .anonymous:
      return true
    case let .session(id):
      return try Sessions.group(of: id.rawValue, in: db) == group
    case let .person(_, account):
      return try Groups.isMember(account, of: group, in: db) || Groups.isHumanAdmin(account, of: group, in: db)
    }
  }

  private static func settingsAdmin(_ actor: Actor, in db: Database) throws -> Bool {
    guard case let .person(_, account) = actor else { return false }
    return try Groups.isHumanAdmin(account, of: .settings, in: db)
  }
}

extension Space {
  /// Whether `path` is a group's instructions: its `/AGENTS.md` or `/.agents/skills/**`.
  public nonisolated func isGroupInstructions(_ path: SpacePath) -> Bool {
    GroupWrites.isInstructions(path)
  }

  /// Writing a group's instructions takes one of its members (a session of the
  /// group, or a member person); the settings group takes a space admin. The
  /// --dev seat is unrestricted.
  public func refuseWrite(_ path: SpacePath, in group: GroupID, by actor: Actor) async throws {
    try await writer.read { db in try GroupWrites.refuseWrite(path, in: group, by: actor, in: db) }
  }

  /// The group a new top-level agent lands in: `requested`, else the
  /// creator's; the creator's group must read it, and the settings group takes
  /// no sessions.
  public func homeGroup(_ requested: GroupID?, creator: GroupID) async throws -> GroupID {
    guard requested != .settings, creator != .settings else { throw SpaceError.groupForbidden(GroupID.settings.rawValue) }
    guard let requested, requested != creator else { return creator }
    guard try await groupExists(requested), try await reads(creator).contains(requested) else {
      throw SpaceError.groupForbidden(requested.rawValue)
    }
    return requested
  }
}
