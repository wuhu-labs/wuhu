#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

public enum Actor: Hashable, Sendable {
  case session(SessionID)
  case person(persona: String, account: AccountID)
  /// A group observer: its group's own role, as a session acting there that is
  /// not its root.
  case observer(Observer)
  case page(Page)
  case publicReader
}

/// Who acts, and in which group: a session's own group, a person's chosen one.
public struct Principal: Hashable, Sendable {
  public let actor: Actor
  public let group: GroupID

  public init(actor: Actor, group: GroupID) {
    self.actor = actor
    self.group = group
  }

  public static func shared(_ actor: Actor) -> Principal {
    Principal(actor: actor, group: .shared)
  }

  public var member: String? {
    switch actor {
    case let .session(id): id.rawValue
    case let .person(persona, _): persona
    case let .observer(observer): observer.member
    case .page, .publicReader: nil
    }
  }

  public func speaking(as persona: String) -> Principal {
    guard case let .person(_, account) = actor else { return self }
    return Principal(actor: .person(persona: persona, account: account), group: group)
  }
}

public struct GroupRecord: Hashable, Sendable {
  public let id: GroupID
  public let alias: String?
  public let name: String?
  public let createdAt: Date
  public let visibility: GroupVisibility
  public let secretsScope: ReachScope
  public let removedAt: Date?
}

extension Space {
  public func groups() async throws -> [GroupRecord] {
    cell.groups()
  }

  public func group(_ id: GroupID) async throws -> GroupRecord? {
    cell(of: id).record()
  }

  /// The groups sessions acting in `group` read.
  public func reads(_ group: GroupID) async throws -> Set<GroupID> {
    cell.reach(of: group)
  }

  /// The groups `principal` reads.
  public func reads(for principal: Principal) async throws -> Set<GroupID> {
    cell.readable(by: principal)
  }

  /// A live group: one that exists and was not removed.
  public func groupExists(_ group: GroupID) async throws -> Bool {
    cell(of: group).record() != nil
  }

  /// The groups an account is listed in, by any role.
  public func memberGroups(of account: AccountID) async throws -> Set<GroupID> {
    cell.memberGroups(of: account)
  }

  /// A session acts in its own group.
  public func principal(of session: SessionID) async throws -> Principal {
    Principal(actor: .session(session), group: cell.group(of: session))
  }

  /// What `actor` may do in `group` acting out of `acting`.
  public func role(of actor: Actor, in group: GroupID, acting: GroupID) async throws -> GroupRole? {
    cell(of: group).role(of: actor, acting: acting)
  }

  public func role(of principal: Principal, in group: GroupID) async throws -> GroupRole? {
    try await role(of: principal.actor, in: group, acting: principal.group)
  }

  /// Whether `group` may write `target`: the same role a machine's or a
  /// secret's switch reads.
  public func writes(_ group: GroupID, in target: GroupID) async throws -> Bool {
    cell(of: target).writes(from: group)
  }

  public func isAdmin(_ actor: Actor, of group: GroupID, acting: GroupID) async throws -> Bool {
    try await role(of: actor, in: group, acting: acting) == .admin
  }

  /// A live person holding `admin` in `group`, directly or as a space admin.
  public func isHumanAdmin(_ account: AccountID, of group: GroupID) async throws -> Bool {
    cell(of: group).isHumanAdmin(account)
  }

  public func isGuest(_ account: AccountID) async throws -> Bool {
    cell.isGuest(account)
  }

  public func setGrant(
    _ subject: GroupGrant.Subject, _ id: String, role: GroupRole, in group: GroupID, by actor: Actor, acting: GroupID,
  ) async throws {
    try requireAdmin(actor, of: group, acting: acting)
    let created = SQLiteDateFormat.string(from: dateGen.now)
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.setGrant(subject, id, role: role, created: created) }
  }

  public func removeGrant(_ subject: GroupGrant.Subject, _ id: String, in group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try requireAdmin(actor, of: group, acting: acting)
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.removeGrant(subject, id) }
  }

  /// Opens a group to every member, or closes it back to its list.
  public func setVisibility(_ visibility: GroupVisibility, of group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try requireAdmin(actor, of: group, acting: acting)
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.setVisibility(visibility) }
  }

  /// Whether a group's secrets open to its owner group alone or to everyone who
  /// can reach it.
  public func setSecretsScope(_ scope: ReachScope, of group: GroupID, by actor: Actor, acting: GroupID) async throws {
    try requireAdmin(actor, of: group, acting: acting)
    try await worker.call(GroupCell.ID(group.rawValue)) { try $0.setSecretsScope(scope) }
  }

  func requireAdmin(_ actor: Actor, of group: GroupID, acting: GroupID) throws {
    guard cell(of: group).role(of: actor, acting: acting) == .admin else { throw SpaceError.groupForbidden(group.rawValue) }
  }
}

extension GroupRecord {
  init(row: GroupRow, alias: String?) {
    self.init(
      id: GroupID(rawValue: row.id),
      alias: alias,
      name: row.name,
      createdAt: (try? SQLiteDateFormat.date(from: row.createdAt)) ?? Date(timeIntervalSince1970: 0),
      visibility: GroupVisibility(rawValue: row.visibility)!,
      secretsScope: ReachScope(rawValue: row.secretsScope)!,
      removedAt: row.removedAt.flatMap { try? SQLiteDateFormat.date(from: $0) },
    )
  }
}
