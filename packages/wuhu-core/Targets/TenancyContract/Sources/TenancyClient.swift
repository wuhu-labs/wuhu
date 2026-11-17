import struct MachineContract.MachineID
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID

/// The space's side of what another family asks out of step: the reads over the space cell's names, devices and groups,
/// and the writes that own them. Every write is a call on its owner; the server supplies the implementation.
public struct TenancyClient: Sendable {
  public var deviceLinks: @Sendable () async -> [MachineID: String]
  public var deviceAccounts: @Sendable (MachineID) async -> [AccountID]
  public var device: @Sendable (String) async -> DeviceRecord?
  public var groups: @Sendable () async -> [GroupID]
  public var group: @Sendable (String) async -> GroupID?
  public var reach: @Sendable (GroupID) async -> Set<GroupID>

  public var claimMachine: @Sendable (MachineID, String) async throws -> Void
  public var annotateDevice: @Sendable (String, MachineID?) async throws -> DeviceRecord
  public var detachMachine: @Sendable (MachineID, AccountID) async throws -> Void
  public var freeMachine: @Sendable (MachineID) async throws -> Void
  public var renameMachine: @Sendable (MachineID, String) async throws -> Void

  public init(
    deviceLinks: @escaping @Sendable () async -> [MachineID: String],
    deviceAccounts: @escaping @Sendable (MachineID) async -> [AccountID],
    device: @escaping @Sendable (String) async -> DeviceRecord?,
    groups: @escaping @Sendable () async -> [GroupID],
    group: @escaping @Sendable (String) async -> GroupID?,
    reach: @escaping @Sendable (GroupID) async -> Set<GroupID>,
    claimMachine: @escaping @Sendable (MachineID, String) async throws -> Void,
    annotateDevice: @escaping @Sendable (String, MachineID?) async throws -> DeviceRecord,
    detachMachine: @escaping @Sendable (MachineID, AccountID) async throws -> Void,
    freeMachine: @escaping @Sendable (MachineID) async throws -> Void,
    renameMachine: @escaping @Sendable (MachineID, String) async throws -> Void,
  ) {
    self.deviceLinks = deviceLinks
    self.deviceAccounts = deviceAccounts
    self.device = device
    self.groups = groups
    self.group = group
    self.reach = reach
    self.claimMachine = claimMachine
    self.annotateDevice = annotateDevice
    self.detachMachine = detachMachine
    self.freeMachine = freeMachine
    self.renameMachine = renameMachine
  }
}
