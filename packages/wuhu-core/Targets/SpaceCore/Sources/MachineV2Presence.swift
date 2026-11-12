#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID

public enum MachineV2Presence: String, Sendable { case attached, detached, lost }

public struct MachineV2PresenceEvidence: Sendable {
  public let state: MachineV2Presence
  public let observedAt: Date
  public let reason: String?
}

extension Space {
  public func machineV2Members(group: GroupID) async throws -> [String] {
    cell.machineV2Members(group: group)
  }

  public func machineV2PresenceEvidence(_ machine: String, group: GroupID) async throws -> MachineV2PresenceEvidence? {
    worker.cell(MachineCell.ID(machine)).presenceEvidence(group: group)
  }
}
