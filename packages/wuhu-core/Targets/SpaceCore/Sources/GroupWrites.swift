import struct SpaceContract.GroupID
import struct SpaceFS.SpacePath

enum GroupWrites {
  static func isInstructions(_ path: SpacePath) -> Bool {
    let components = path.components
    if components == ["AGENTS.md"] { return true }
    if components.first == ".agents", components.count == 1 || components[1] == "skills" { return true }
    return false
  }
}

extension Space {
  /// Whether `path` is a group's instructions: its `/AGENTS.md` or `/.agents/skills/**`.
  public nonisolated func isGroupInstructions(_ path: SpacePath) -> Bool {
    GroupWrites.isInstructions(path)
  }

  public func refuseWrite(_ path: SpacePath, in group: GroupID, by actor: Actor, acting: GroupID) async throws {
    if SessionTranscripts.contains(path.rawValue) || RenderedFiles.contains(path.rawValue) { throw SpaceError.sentViewReadOnly(path.rawValue) }
    try cell(of: group).refusesWrite(path, by: actor, acting: acting)
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
    case .publicReader:
      false
    case .person:
      try await role(of: creator, in: requested).map { $0 >= .write } == true
    case .session where requested == creator.group:
      true
    case .session:
      try await role(of: creator, in: requested) == .admin
    case .observer, .page:
      requested == creator.group
    }
    guard admitted else { throw SpaceError.groupForbidden(requested.rawValue) }
    return requested
  }
}
