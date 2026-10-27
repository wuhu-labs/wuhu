#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import struct SpaceContract.GroupID
import struct SpaceContract.GroupSummary
import SpaceCore

extension SpaceToolContext {
  public func discoveryContext(contentHost: String?) async throws -> JSONValue {
    let caller = try await discoveryPrincipal()
    let session: JSONValue = if case let .session(id) = caller.actor { .string(id.rawValue) } else { .null }
    return .object([
      "session": session,
      "group": .string(caller.group.rawValue),
      "contentHost": contentHost.map { .string($0.replacingOccurrences(of: "{group}", with: caller.group.rawValue)) } ?? .null,
      // The space revision now: a script's module graph freezes at it.
      "rev": .integer(try await space.currentRevision()),
    ])
  }

  public func discoveryGroups(dev: Bool = false) async throws -> [GroupSummary] {
    let caller = try await discoveryPrincipal()
    let live = try await space.groups().filter { $0.removedAt == nil }
    let member: Set<GroupID>
    let readable: Set<GroupID>
    switch caller.actor {
    case .session, .observer:
      member = [caller.group]
      readable = try await space.reads(for: caller)
    case .person:
      member = try await space.writableGroups(for: caller)
      readable = try await space.reads(for: caller)
    case .anonymous:
      let all = dev ? Set(live.map(\.id)) : []
      member = all
      readable = all
    }
    // The dev seat acts in every group, so it administers every group too.
    let administered: Set<GroupID> = if case .anonymous = caller.actor {
      dev ? Set(live.map(\.id)) : []
    } else {
      try await space.administeredGroups(by: caller.actor, acting: caller.group)
    }
    return live
      .filter { $0.id != .settings && $0.personalAccount == nil }
      .map { group in
        GroupSummary(
          id: group.id.rawValue, member: member.contains(group.id), readable: readable.contains(group.id),
          admin: administered.contains(group.id),
        )
      }
  }

  private func discoveryPrincipal() async throws -> Principal {
    if case let .session(id) = principal.actor { return try await space.principal(of: id) }
    return principal
  }
}
