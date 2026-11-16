import struct SpaceIDs.AccountID
import Wuwei

public protocol SettingsReading {
  func isSpaceAdmin(account: AccountID) -> Bool
}

public struct GroupCells: Sendable {
  public var settings: @Sendable (any CellReading) -> any SettingsReading

  public init(settings: @escaping @Sendable (any CellReading) -> any SettingsReading) {
    self.settings = settings
  }
}

extension CellContext {
  public func settings() -> any SettingsReading {
    dependency(GroupCells.self).settings(self)
  }
}
