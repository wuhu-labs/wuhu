#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import struct SpaceContract.GroupID
import struct SpaceFS.SpacePath

/// What writing a group's files takes: its instructions (its `/AGENTS.md` and
/// `/.agents/skills/**`) follow the same rule as every other file, and the
/// settings group takes only a space admin.
enum GroupWrites {
  static func isInstructions(_ path: SpacePath) -> Bool {
    let components = path.components
    if components == ["AGENTS.md"] { return true }
    if components.first == ".agents", components.count == 1 || components[1] == "skills" { return true }
    return false
  }

  static func refuseWrite(_ path: SpacePath, in group: GroupID, by actor: Actor, acting: GroupID, in db: Database) throws {
    if case .anonymous = actor { return }
    guard let held = try GroupAccess.role(of: actor, in: group, acting: acting, in: db) else {
      throw SpaceError.notFound(path.rawValue)
    }
    guard held >= .write else { throw SpaceError.forbiddenWrite(path: path.rawValue, group: group.rawValue) }
  }
}

extension Space {
  /// Whether `path` is a group's instructions: its `/AGENTS.md` or `/.agents/skills/**`.
  public nonisolated func isGroupInstructions(_ path: SpacePath) -> Bool {
    GroupWrites.isInstructions(path)
  }

  /// Writing a group's file takes a write role in it; the settings group takes
  /// a space admin. The --dev seat is unrestricted.
  public func refuseWrite(_ path: SpacePath, in group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try await writer.read { db in try GroupWrites.refuseWrite(path, in: group, by: actor, acting: acting, in: db) }
  }

  /// The group a new top-level agent lands in: `requested`, else the
  /// creator's. A person may place one where they write, their acting group
  /// included; a session in its own group, or only where its group
  /// administers — never by landing in an open group it merely writes. The
  /// settings group takes no sessions.
  public func homeGroup(_ requested: GroupID?, creator: Principal) async throws -> GroupID {
    guard requested != .settings, creator.group != .settings else { throw SpaceError.groupForbidden(GroupID.settings.rawValue) }
    let requested = requested ?? creator.group
    guard try await groupExists(requested) else { throw SpaceError.groupForbidden(requested.rawValue) }
    let admitted: Bool = switch creator.actor {
    case .anonymous:
      true
    case .person:
      try await role(of: creator, in: requested).map { $0 >= .write } == true
    case .session where requested == creator.group:
      true
    case .session:
      try await role(of: creator, in: requested) == .admin
    case .observer:
      requested == creator.group
    }
    guard admitted else { throw SpaceError.groupForbidden(requested.rawValue) }
    return requested
  }
}
