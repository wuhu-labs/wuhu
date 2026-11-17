import struct MachineContract.MachineID
import struct SpaceIDs.GroupID
import Wuwei

/// What the space cell answers about a machine's identity: its current name, the machine a spelling names, and the
/// groups a reach filter needs.
public protocol SpaceReading {
  func machineName(_ id: MachineID) -> String?
  func machineNames() -> [MachineID: String]
  func machineID(named name: String) -> MachineID?
  /// The groups `group` may write: its own, the groups that list it at write or above, and the open ones.
  func writableGroups(of group: GroupID) -> Set<GroupID>
}

public struct TenancyCells: Sendable {
  public var space: @Sendable (any CellReading) -> any SpaceReading

  public init(space: @escaping @Sendable (any CellReading) -> any SpaceReading) {
    self.space = space
  }
}

extension CellContext {
  public func space() -> any SpaceReading {
    dependency(TenancyCells.self).space(self)
  }
}
