import struct MachineContract.MachineID
import struct SpaceContract.GroupID

/// Everything a machine's birth carries: the name the space cell reserved, the account the person cell made and the
/// group whose tree holds its notes.
public struct MachineClaim: Codable, Hashable, Sendable {
  public var id: MachineID
  public var account: AccountID
  public var name: String
  public var group: GroupID
  public var scope: ReachScope
  public var created: String
}
