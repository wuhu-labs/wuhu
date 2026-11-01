import struct SpaceContract.GroupID
import enum SpaceContract.WmdAccess
import SpaceCore
import SpaceFS

public struct WmdTarget: Sendable {
  public let group: GroupID
  public let path: SpacePath
  public let access: WmdAccess
  /// The principal as its presence names it.
  public let name: String
}

extension SpaceToolContext {
  /// The live document a socket opens: readable, or the address answers as missing.
  public func wmdTarget(_ address: String) async throws -> WmdTarget {
    let (group, path, _) = try await spaceTarget(address)
    let access: WmdAccess
    do {
      try await refuseWrite(path, in: group)
      access = .write
    } catch SpaceError.forbiddenWrite, SpaceError.foreignHome, ToolRunError.failed(code: .unauthorized, _, _, _) {
      access = .read
    }
    return WmdTarget(group: group, path: path, access: access, name: try await presenceName())
  }

  private func presenceName() async throws -> String {
    switch principal.actor {
    case let .person(persona, _):
      let profile = try await space.userProfile(principal: persona)
      return profile?.displayName ?? profile?.handle ?? persona
    case let .session(id): return try await space.sessions.record(id).title
    case let .observer(observer): return observer.member
    case .page: return "page"
    case .anonymous: return "dev"
    }
  }
}
