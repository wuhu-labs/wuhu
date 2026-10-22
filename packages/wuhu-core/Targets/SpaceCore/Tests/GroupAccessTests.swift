import DeterministicDependencies
import Foundation
import struct SpaceContract.GroupID
@testable import SpaceCore
import struct SpaceFS.SpacePath
import Testing

// The one access rule: open groups take every member in, private groups take
// their list, and a role means what it says.
@Suite(.deterministicDependencies) struct GroupAccessTests {
  static let team = GroupID(rawValue: "team")
  static let studio = GroupID(rawValue: "studio")

  func space() async throws -> Space {
    let space = try makeSpace()
    try await space.writer.write { db in
      for id in [Self.team, Self.studio] {
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00Z')", arguments: [id.rawValue])
      }
    }
    return space
  }

  @Test func anOpenGroupTakesEveryMemberAndSessionButAGuest() async throws {
    let space = try await space()
    let member = try await space.addAccount(kind: .human, name: "member")
    let guest = try await space.addAccount(kind: .human, name: "guest", guest: true)
    try await space.setVisibility(.open, of: Self.team, by: .anonymous, acting: Self.team)
    #expect(try await space.role(of: .person(persona: "member", account: member.id), in: Self.team, acting: .shared) == .write)
    #expect(try await space.role(of: .person(persona: "guest", account: guest.id), in: Self.team, acting: Self.team) == nil)
    let session = try await space.sessions.createSession(group: Self.studio, title: "s", kind: .agent, createdBy: "owner", model: .test)
    #expect(try await space.role(of: .session(session), in: Self.team, acting: Self.studio) == .write)
  }

  @Test func aPrivateGroupTakesItsListAndReadIsReadOnly() async throws {
    let space = try await space()
    let reader = try await space.addAccount(kind: .human, name: "reader")
    let readerGroup = try #require(try await space.personalGroup(of: reader.id))
    let writer = try await space.sessions.createSession(group: Self.studio, title: "w", kind: .agent, createdBy: "owner", model: .test)
    try await space.setGrant(.account, reader.id.rawValue, role: .read, in: Self.team, by: .anonymous, acting: Self.team)
    try await space.setGrant(.group, Self.studio.rawValue, role: .write, in: Self.team, by: .anonymous, acting: Self.team)
    #expect(try await space.role(of: .person(persona: "reader", account: reader.id), in: Self.team, acting: readerGroup) == .read)
    #expect(try await space.role(of: .session(writer), in: Self.team, acting: Self.studio) == .write)
    #expect(try await space.role(of: .person(persona: "reader", account: reader.id), in: Self.team, acting: Self.team) == .read)
    // A read entry writes nothing.
    await #expect(throws: SpaceError.forbiddenWrite(path: "/plan.md", group: "team")) {
      try await space.refuseWrite(
        try SpacePath(validating: "/plan.md"), in: Self.team, by: .person(persona: "reader", account: reader.id), acting: readerGroup,
      )
    }
  }

  @Test func aReadEntryIsNoMembershipButTheListIsVisibleToItsPeople() async throws {
    let space = try await space()
    let reader = try await space.addAccount(kind: .human, name: "reader")
    let readerGroup = try #require(try await space.personalGroup(of: reader.id))
    try await space.setGrant(.account, reader.id.rawValue, role: .read, in: Self.team, by: .anonymous, acting: Self.team)
    let principal = Principal(actor: .person(persona: "reader", account: reader.id), group: readerGroup)
    #expect(try await space.grants(of: Self.team, by: principal) == [GroupGrant(subject: .account, id: reader.id.rawValue, role: .read)])
    #expect(try await space.role(of: principal, in: Self.team) != nil)
    // Only an admin changes the list, and only for an ordinary group.
    await #expect(throws: SpaceError.groupForbidden("team")) {
      try await space.setGrant(.account, reader.id.rawValue, role: .write, in: Self.team, by: principal.actor, acting: readerGroup)
    }
    let own = try #require(try await space.personalGroup(of: reader.id))
    await #expect(throws: SpaceError.personalGroupPrivate(own.rawValue)) {
      try await space.setGrant(.account, reader.id.rawValue, role: .read, in: own, by: .anonymous, acting: own)
    }
  }

  @Test func aSpaceAdminAdministersEveryGroupButAnotherPersonsOwn() async throws {
    let space = try await space()
    let admin = try await space.addAccount(kind: .human, name: "admin", admin: true)
    let other = try await space.addAccount(kind: .human, name: "other")
    let others = try #require(try await space.personalGroup(of: other.id))
    let principal = Principal(actor: .person(persona: "admin", account: admin.id), group: .shared)
    #expect(try await space.role(of: principal, in: Self.team) == .admin)
    #expect(try await space.role(of: principal, in: .shared) == .admin)
    #expect(try await space.role(of: principal, in: others) == nil)
    #expect(try await space.role(of: principal, in: .settings) == .admin)
    try await space.setVisibility(.open, of: Self.team, by: principal.actor, acting: .shared)
    #expect(try await space.group(Self.team)?.visibility == .open)
  }

  @Test func theSettingsGroupIsReadableByEveryoneAndWritableBySpaceAdmins() async throws {
    let space = try await space()
    let member = try await space.addAccount(kind: .human, name: "member")
    let admin = try await space.addAccount(kind: .human, name: "admin", admin: true)
    let session = try await space.sessions.createSession(group: Self.team, title: "s", kind: .agent, createdBy: "owner", model: .test)
    #expect(try await space.role(of: .person(persona: "member", account: member.id), in: .settings, acting: .shared) == .read)
    #expect(try await space.role(of: .session(session), in: .settings, acting: Self.team) == .read)
    #expect(try await space.role(of: .person(persona: "admin", account: admin.id), in: .settings, acting: .shared) == .admin)
    #expect(try await space.reads(.shared).contains(.settings))
    #expect(try await space.reads(Self.team).contains(.settings))
  }

  @Test func aGuestsReachIsItsListAlone() async throws {
    let space = try await space()
    let guest = try await space.addAccount(kind: .human, name: "guest", guest: true)
    try await space.setGrant(.account, guest.id.rawValue, role: .write, in: Self.team, by: .anonymous, acting: Self.team)
    let principal = Principal(actor: .person(persona: "guest", account: guest.id), group: Self.team)
    #expect(try await space.reads(for: principal) == [Self.team, .settings])
    #expect(try await space.role(of: principal, in: .shared) == nil)
    // A guest holds no personal group and takes no admin.
    #expect(try await space.personalGroup(of: guest.id) == nil)
    await #expect(throws: SpaceError.notAPerson(guest.id.rawValue)) { try await space.setAdmin(guest.id, admin: true) }
  }

  @Test func theSettingsGroupAGuestAdminAndAGroupItselfAllStayOutOfTheList() async throws {
    let space = try await space()
    let guest = try await space.addAccount(kind: .human, name: "guest", guest: true)
    let admin = try await space.addAccount(kind: .human, name: "admin", admin: true)
    let actor = Actor.person(persona: "admin", account: admin.id)
    // The settings group's admins are the account admin verb's, which guards
    // the last admin; a list edit is refused for the group's own admins too.
    await #expect(throws: SpaceError.settingsGroupAccess) {
      try await space.setGrant(.account, guest.id.rawValue, role: .admin, in: .settings, by: actor, acting: .settings)
    }
    await #expect(throws: SpaceError.settingsGroupAccess) {
      try await space.removeGrant(.account, admin.id.rawValue, in: .settings, by: actor, acting: .settings)
    }
    #expect(try await space.isHumanAdmin(admin.id, of: .settings))
    let settingsList = try await space.grants(of: .settings, by: Principal(actor: actor, group: .settings))
    #expect(!settingsList.contains { $0.id == guest.id.rawValue })
    // A guest takes no admin anywhere.
    await #expect(throws: SpaceError.groupForbidden(Self.team.rawValue)) {
      try await space.setGrant(.account, guest.id.rawValue, role: .admin, in: Self.team, by: actor, acting: .shared)
    }
    // No group is listed in itself.
    await #expect(throws: SpaceError.groupForbidden(Self.team.rawValue)) {
      try await space.setGrant(.group, Self.team.rawValue, role: .read, in: Self.team, by: actor, acting: .shared)
    }
  }

  @Test func aMachineOpensToItsOwnerGroupOrToEveryGroupThatWritesIt() async throws {
    let space = try await space()
    let machine = try await space.addMachine(name: "box", group: Self.team)
    #expect(machine.scope == .owner)
    // studio reads team's list but writes nothing there.
    try await space.setGrant(.group, Self.studio.rawValue, role: .read, in: Self.team, by: .anonymous, acting: Self.team)
    #expect(try await space.resolveMachine("box", usableFrom: Self.studio) == nil)
    #expect(try await space.resolveMachine("box", usableFrom: Self.team) != nil)
    _ = try await space.setMachineScope(machine.id, scope: .reachable)
    // Reading the owner group is still not using its machines.
    #expect(try await space.resolveMachine("box", usableFrom: Self.studio) == nil)
    try await space.setGrant(.group, Self.studio.rawValue, role: .write, in: Self.team, by: .anonymous, acting: Self.team)
    #expect(try await space.resolveMachine("box", usableFrom: Self.studio) != nil)
    #expect(try await space.resolveMachine("box", usableFrom: .shared) == nil)
    #expect(try await space.machines(usableFrom: Self.studio).map(\.id) == [machine.id])
    #expect(try await space.machines(usableFrom: .shared).isEmpty)
  }

  @Test func aSecretsSwitchOpensTheStoreToEveryGroupThatWritesIt() async throws {
    let space = try await space()
    try await space.setGrant(.group, Self.studio.rawValue, role: .read, in: Self.team, by: .anonymous, acting: Self.team)
    #expect(try await space.group(Self.team)?.secretsScope == .owner)
    try await space.setSecretsScope(.reachable, of: Self.team, by: .anonymous, acting: Self.team)
    #expect(try await space.group(Self.team)?.secretsScope == .reachable)
  }
}
