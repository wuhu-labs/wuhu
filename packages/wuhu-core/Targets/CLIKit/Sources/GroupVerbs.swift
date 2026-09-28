import JSONValue
import SpaceClient
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupSettings
import struct SpaceContract.GroupSummary
import struct SpaceContract.ServerInfo

extension Executor {
  // A selected group is never dropped: a server that does not advertise
  // groups would act in its only group, which is not the one asked for.
  mutating func requireGroups(space: String, selected: String?) async throws {
    guard !self.groupsConfirmed.contains(space) else { return }
    guard try await self.advertisesGroups(space: space) else {
      throw CLIError(message: "this server has no groups" + (selected.map { "; \($0) comes from \(self.group.label)" } ?? ""))
    }
    self.groupsConfirmed.insert(space)
  }

  mutating func requireGroup(_ group: String, space: String) async throws {
    try await self.requireGroups(space: space, selected: nil)
    let selected = self.group
    self.select(.none)
    defer { self.select(selected) }
    let groups: [GroupSummary] = try await self.authenticated(space).api(.get, "/v1/groups")
    guard groups.contains(where: { $0.id == group }) else {
      throw CLIError(message: "\(space) has no group \(group); wuhu group list shows its groups")
    }
  }

  mutating func groupList() async throws {
    let space = try self.wallet.pinnedSpace()
    try await self.requireGroups(space: space, selected: self.group.group)
    let groups: [GroupSummary] = try await self.authenticated(space).api(.get, "/v1/groups")
    await self.runner.stdout(groups.map { $0.id + "\n" }.joined())
  }

  mutating func groupUse(_ group: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    if let group {
      guard isValidGroupID(group) else {
        throw UsageError(message: "group use: \(group) is not a group id: lowercase letters, digits and inner hyphens")
      }
      try await self.requireGroup(group, space: space)
    }
    let config = try self.wallet.setGroup(group)
    await self.runner.stdout((group.map { "group \($0)" } ?? "cleared the group") + " -> \(config.path)\n")
    if self.group.source == .flag || self.group.source == .environment {
      await self.runner.stderr("note: \(self.group.label) still overrides it\n")
    }
  }

  mutating func groupCurrent() async throws {
    if let group = self.group.group {
      await self.runner.stdout("\(group) (\(self.group.label))\n")
      return
    }
    let space = try self.wallet.pinnedSpace()
    let info: ServerInfo = try await self.authenticated(space).api(.get, "/v1/server")
    guard info.features?.contains(GroupHeader.feature) == true, let group = info.group else {
      await self.runner.stdout("none (this server has no groups)\n")
      return
    }
    await self.runner.stdout("\(group) (" + (self.session == nil ? "the server's default" : "this session's group") + ")\n")
  }

  mutating func groupSet(_ group: String, spaceLayer: Bool) async throws {
    let space = try self.wallet.pinnedSpace()
    try await self.requireGroups(space: space, selected: self.group.group)
    let body: JSONValue = .object(["spaceLayer": .bool(spaceLayer)])
    let settings: GroupSettings = try await self.authenticated(space).api(.put, "/v1/groups/\(group)", body: body)
    await self.runner.stdout("\(settings.id) space-layer \(settings.spaceLayer ? "on" : "off")\n")
  }

  // Only an answer without the feature means no groups; a failed probe is
  // reported as itself.
  private func advertisesGroups(space: String) async throws -> Bool {
    let info: ServerInfo = try await self.client(space).api(.get, "/v1/server")
    return info.features?.contains(GroupHeader.feature) == true
  }
}
