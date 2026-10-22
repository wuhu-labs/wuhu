import JSONValue
import SpaceClient
import struct SpaceContract.GroupDetail
import enum SpaceContract.GroupHeader
import struct SpaceContract.GroupSummary
import struct SpaceContract.ServerInfo

extension Executor {
  // A selected group is never dropped: a server that does not advertise
  // groups would act in its only group, which is not the one asked for.
  mutating func requireGroups(space: String, selected: String?) async throws { guard !self.groupsConfirmed.contains(space) else { return }
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

  // A group's access state: open or private, the secrets switch, the list.
  mutating func groupShow(_ group: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let detail: GroupDetail = try await self.authenticated(space).api(.get, "/v1/group/\(group)")
    await self.runner.stdout(detailLines(detail))
  }

  mutating func groupOpen(_ group: String, open: Bool) async throws {
    let space = try self.wallet.pinnedSpace()
    let detail: GroupDetail = try await self.authenticated(space).api(
      .put, "/v1/group/\(group)", body: .object(["open": .bool(open)]),
    )
    await self.runner.stdout(detailLines(detail))
  }

  mutating func groupSecrets(_ group: String, scope: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let detail: GroupDetail = try await self.authenticated(space).api(
      .put, "/v1/group/\(group)", body: .object(["secrets": .string(scope)]),
    )
    await self.runner.stdout(detailLines(detail))
  }

  mutating func groupGrant(group: String, role: String, subject: String) async throws {
    let space = try self.wallet.pinnedSpace()
    _ = try await self.authenticated(space).api(.put, "/v1/group/\(group)/access", body: .object([
      "kind": .string(subjectKind(subject)), "id": .string(subject), "role": .string(role),
    ])) as JSONValue
    await self.runner.stdout("\(subject) \(role) in \(group)\n")
  }

  mutating func groupRevoke(group: String, subject: String) async throws {
    let space = try self.wallet.pinnedSpace()
    _ = try await self.authenticated(space).api(
      .delete, "/v1/group/\(group)/access?kind=\(subjectKind(subject))&id=\(subject)",
    ) as JSONValue
    await self.runner.stdout("\(subject) is no longer in \(group)\n")
  }

  // An account id is prefixed; anything else names a group.
  private func subjectKind(_ subject: String) -> String {
    subject.hasPrefix("ac_") ? "account" : "group"
  }

  private func detailLines(_ detail: GroupDetail) -> String {
    var lines = ["group \(detail.id) \(detail.open ? "open" : "private") secrets \(detail.secrets)"]
    lines += detail.entries.map { "\($0.kind) \($0.id) \($0.role)" }
    return lines.joined(separator: "\n") + "\n"
  }

  // Only an answer without the feature means no groups; a failed probe is
  // reported as itself.
  private func advertisesGroups(space: String) async throws -> Bool {
    let info: ServerInfo = try await self.client(space).api(.get, "/v1/server")
    return info.features?.contains(GroupHeader.feature) == true
  }
}
