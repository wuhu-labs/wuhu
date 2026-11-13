#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import OrderedCollections
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
      "revs": .object(OrderedDictionary(uniqueKeysWithValues: space.currentRevisions(for: caller).sorted { $0.key < $1.key }.map { ($0.key, .integer($0.value)) })),
    ])
  }

  public func discoveryGroups(dev: Bool = false) async throws -> [GroupSummary] {
    let caller = try await discoveryPrincipal()
    let cell = space.cell
    let live = cell.groups().filter { $0.removedAt == nil }
    let member: Set<GroupID>
    let readable: Set<GroupID>
    switch caller.actor {
    case .session, .observer, .page:
      member = [caller.group]
      readable = cell.readable(by: caller)
    case .person:
      member = cell.writable(by: caller)
      readable = cell.readable(by: caller)
    case .anonymous:
      let all = dev ? Set(live.map(\.id)) : []
      member = all
      readable = all
    }
    // The dev seat acts in every group, so it administers every group too.
    let administered: Set<GroupID>
    let named: Bool
    if case .anonymous = caller.actor {
      administered = dev ? Set(live.map(\.id)) : []
      named = dev
    } else {
      administered = cell.administered(by: caller)
      named = true
    }
    return live
      .filter { $0.id != .settings && $0.personalAccount == nil }
      .map { group in
        GroupSummary(
          id: group.id.rawValue, name: named ? group.name : nil, member: member.contains(group.id), readable: readable.contains(group.id),
          admin: administered.contains(group.id),
        )
      }
  }

  private func discoveryPrincipal() async throws -> Principal {
    if case let .session(id) = principal.actor { return try await space.principal(of: id) }
    return principal
  }
}
