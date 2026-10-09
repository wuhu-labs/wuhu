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
    ])
  }

  public func discoveryGroups(dev: Bool = false) async throws -> [GroupSummary] {
    let caller = try await discoveryPrincipal()
    let member: Set<GroupID>
    let readable: Set<GroupID>
    switch caller.actor {
    case .session:
      member = [caller.group]
      readable = try await space.reads(caller.group)
    case let .person(_, account):
      member = try await space.memberGroups(of: account)
      readable = try await space.reads(member)
    case .anonymous:
      let all = dev ? Set(try await space.groups().filter { $0.removedAt == nil }.map(\.id)) : []
      member = all
      readable = all
    }
    return try await space.groups().filter { $0.removedAt == nil }.map {
      GroupSummary(id: $0.id.rawValue, member: member.contains($0.id), readable: readable.contains($0.id))
    }
  }

  private func discoveryPrincipal() async throws -> Principal {
    if case let .session(id) = principal.actor { return try await space.principal(of: id) }
    return principal
  }
}
