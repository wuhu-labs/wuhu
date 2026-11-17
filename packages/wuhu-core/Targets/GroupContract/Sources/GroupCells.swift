import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import Wuwei

/// What the settings group answers about the space: whether an account administers it.
public protocol SettingsReading {
  func isSpaceAdmin(account: AccountID) -> Bool
}

/// What one group answers about who may do what in it. Every read is over one group's own row and list; its callers
/// hold a group handle and ask through it.
public protocol GroupReading {
  func role(ofSession id: SessionID) -> GroupRole?
  func role(ofAccount id: AccountID, acting: GroupID) -> GroupRole?
  /// The role a group holds here: the reach a machine's or a secret's switch reads.
  func role(ofGroup group: GroupID) -> GroupRole?
  /// Whether the person behind `account` administers this group: its owner, a space admin, or an admin on its list.
  func isHumanAdmin(_ account: AccountID) -> Bool
  /// Whether `group` may write here.
  func writes(from group: GroupID) -> Bool
  /// Whether the group exists and was not removed.
  func exists() -> Bool
}

public struct GroupCells: Sendable {
  public var settings: @Sendable (any CellReading) -> any SettingsReading
  public var group: @Sendable (any CellReading, GroupID) -> any GroupReading

  public init(
    settings: @escaping @Sendable (any CellReading) -> any SettingsReading,
    group: @escaping @Sendable (any CellReading, GroupID) -> any GroupReading,
  ) {
    self.settings = settings
    self.group = group
  }
}

extension CellContext {
  public func settings() -> any SettingsReading {
    dependency(GroupCells.self).settings(self)
  }

  public func group(_ id: GroupID) -> any GroupReading {
    dependency(GroupCells.self).group(self, id)
  }
}
