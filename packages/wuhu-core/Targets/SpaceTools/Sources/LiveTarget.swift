import struct SpaceContract.GroupID
import enum SpaceContract.LiveAccess
import SpaceCore
import SpaceFS

public struct LiveTarget: Sendable {
  public let group: GroupID
  public let path: SpacePath
  public let access: LiveAccess
  /// The principal as its presence names it.
  public let name: String
}

extension SpaceToolContext {
  /// The live document a socket opens: readable, or the address answers as missing.
  public func liveTarget(_ address: String) async throws -> LiveTarget {
    let (group, path, _) = try await spaceTarget(address)
    let access: LiveAccess
    do {
      try await refuseWrite(path, in: group)
      access = .write
    } catch SpaceError.forbiddenWrite, SpaceError.foreignHome, ToolRunError.failed(code: .unauthorized, _, _, _) {
      access = .read
    }
    return LiveTarget(group: group, path: path, access: access, name: try await presenceName())
  }

  private func presenceName() async throws -> String {
    switch principal.actor {
    case let .person(persona, _):
      let profile = try await space.userProfile(principal: persona)
      return profile?.displayName ?? profile?.handle ?? persona
    case let .session(id): return try await space.sessions.record(id).title
    case let .observer(observer): return observer.member
    case .page: return "page"
    case .publicReader: throw ToolRunError.failed(code: .unauthorized, message: "live presence requires a member", hint: nil)
    }
  }
}
