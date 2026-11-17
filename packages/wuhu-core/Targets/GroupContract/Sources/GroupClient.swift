import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID

/// Another family's out-of-step questions about a group: the same one access rule the group cell applies, asked by id.
public struct GroupClient: Sendable {
  public var roleOfSession: @Sendable (SessionID, GroupID) async -> GroupRole?
  public var roleOfAccount: @Sendable (AccountID, GroupID, GroupID) async -> GroupRole?
  public var roleOfGroup: @Sendable (GroupID, GroupID) async -> GroupRole?
  public var isHumanAdmin: @Sendable (AccountID, GroupID) async -> Bool
  public var writes: @Sendable (GroupID, GroupID) async -> Bool
  public var exists: @Sendable (GroupID) async -> Bool

  public init(
    roleOfSession: @escaping @Sendable (SessionID, GroupID) async -> GroupRole?,
    roleOfAccount: @escaping @Sendable (AccountID, GroupID, GroupID) async -> GroupRole?,
    roleOfGroup: @escaping @Sendable (GroupID, GroupID) async -> GroupRole?,
    isHumanAdmin: @escaping @Sendable (AccountID, GroupID) async -> Bool,
    writes: @escaping @Sendable (GroupID, GroupID) async -> Bool,
    exists: @escaping @Sendable (GroupID) async -> Bool,
  ) {
    self.roleOfSession = roleOfSession
    self.roleOfAccount = roleOfAccount
    self.roleOfGroup = roleOfGroup
    self.isHumanAdmin = isHumanAdmin
    self.writes = writes
    self.exists = exists
  }
}

/// What a machine's move and deletion need of the group's file tree: its notes checkpointed, carried, or removed.
public struct GroupNotes: Sendable {
  public var checkpoint: @Sendable (String, GroupID) async throws -> Void
  public var move: @Sendable (String, GroupID, GroupID) async throws -> Void
  public var delete: @Sendable (String, GroupID) async throws -> Void

  public init(
    checkpoint: @escaping @Sendable (String, GroupID) async throws -> Void,
    move: @escaping @Sendable (String, GroupID, GroupID) async throws -> Void,
    delete: @escaping @Sendable (String, GroupID) async throws -> Void,
  ) {
    self.checkpoint = checkpoint
    self.move = move
    self.delete = delete
  }
}
